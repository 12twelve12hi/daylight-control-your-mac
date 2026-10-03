package com.twelve.daylight.ink.mirror

import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * H.264 screen encoder (PROTOCOL 14): MediaCodec "video/avc" with a `COLOR_FormatSurface` input surface fed by ONE
 * VirtualDisplay of the MediaProjection. Every codec and display call runs on one HandlerThread ("drain thread");
 * the codec runs in asynchronous mode with its callback on that thread, so after `release()` no stale output can
 * follow a new MIRROR_HELLO. A restart (new parameters, rotation, thermal cap) reuses the virtual display through
 * `resize` and `setSurface`: Android 14 allows one `createVirtualDisplay` per projection.
 */
class ScreenEncoder(private val sink: Sink) {
    companion object {
        const val TAG = "DaylightInk.mirror"
        const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        const val NOMINAL_FRAME_RATE = 30
        const val REPEAT_PREVIOUS_FRAME_AFTER_US = 250_000L
        const val VIRTUAL_DISPLAY_NAME = "DaylightInkMirror"

        /** The AVC encoders of this device, hardware first; empty means UNSUPPORTED (PROTOCOL 14.3 state 8). */
        fun avcEncoders(): List<String> = runCatching {
            val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(MIME, ignoreCase = true) } }
            infos.sortedBy { info -> if (runCatching { info.isHardwareAccelerated }.getOrDefault(false)) 0 else 1 }.map { it.name }
        }.getOrElse { Log.w(TAG, "codec list failed: $it"); emptyList() }
    }

    /** Called on the drain thread. */
    interface Sink {
        /** The encoder is configured at this size: send MIRROR_HELLO and the session packet now. */
        fun streamStarted(encoderName: String, width: Int, height: Int)
        /** One output buffer: codec config (SPS and PPS) or one access unit. */
        fun output(config: Boolean, keyFrame: Boolean, ptsUs: Long, data: ByteBuffer)
        /** Configure or start failed at every size, or the codec reported an unrecoverable error. */
        fun failed(reason: String)
    }

    data class Display(val width: Int, val height: Int, val densityDpi: Int)

    private val thread = HandlerThread("DaylightInk.mirror.drain").apply { start() }
    val handler = Handler(thread.looper)

    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var projection: MediaProjection? = null
    private var ptsOriginUs = -1L
    private var lastStart: Triple<EncoderParams, Display, MediaProjection>? = null
    private var recoveries = 0
    /** Size of the running encoder, 0 x 0 when stopped. Read on the drain thread only. */
    var size: EncoderSizing.Size = EncoderSizing.Size(0, 0)
        private set

    /** (Re)start for [projection] at [params] on a display of [display]. */
    fun start(projection: MediaProjection, params: EncoderParams, display: Display) {
        handler.post {
            recoveries = 0
            startNow(projection, params, display)
        }
    }

    fun stop() { handler.post { stopCodec() } }

    /** The projection ended: stop the codec and release the virtual display. */
    fun releaseDisplay() {
        handler.post {
            stopCodec()
            runCatching { virtualDisplay?.release() }
            virtualDisplay = null
            projection = null
        }
    }

    /** `PARAMETER_KEY_REQUEST_SYNC_FRAME` (PROTOCOL 14.4 REQUEST_KEY_FRAME, 14.2 backpressure and oversize rules). */
    fun requestSyncFrame() {
        handler.post { requestSyncFrameNow() }
    }

    /** Callable on the drain thread itself (from inside [Sink.output]). */
    fun requestSyncFrameNow() {
        val c = codec ?: return
        runCatching { c.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
            .onFailure { Log.w(TAG, "request sync frame failed: $it") }
    }

    fun quit() {
        releaseDisplay()
        handler.post { thread.quitSafely() }
    }

    private fun startNow(projection: MediaProjection, params: EncoderParams, display: Display) {
        stopCodec()
        lastStart = Triple(params, display, projection)
        val names = avcEncoders()
        if (names.isEmpty()) { sink.failed("no H.264 encoder"); return }
        val sizes = EncoderSizing.candidates(display.width, display.height, params.maxSize)
        for (name in names) {
            for (s in sizes) {
                val ok = configure(name, s, params)
                if (ok) {
                    if (!attach(projection, s, display.densityDpi)) {
                        stopCodec()
                        sink.failed("virtual display refused")
                        return
                    }
                    size = s
                    Log.i(TAG, "encoder $name ${s.width}x${s.height} ${params.bitrateBps} bps fps<=${params.maxFps} key=${params.keyIntervalSeconds}s")
                    sink.streamStarted(name, s.width, s.height)
                    return
                }
            }
        }
        sink.failed("configure failed at every size")
    }

    private fun configure(name: String, s: EncoderSizing.Size, params: EncoderParams): Boolean {
        val format = MediaFormat.createVideoFormat(MIME, s.width, s.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, params.bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, NOMINAL_FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, params.keyIntervalSeconds)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, REPEAT_PREVIOUS_FRAME_AFTER_US)
            // API 29: the encoder drops surface frames above the cap (the thermal rule halves it).
            setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, params.maxFps.toFloat())
        }
        var c: MediaCodec? = null
        var surface: Surface? = null
        return try {
            c = MediaCodec.createByCodecName(name)
            c.setCallback(callback, handler)
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = c.createInputSurface()
            c.start()
            codec = c
            inputSurface = surface
            ptsOriginUs = -1L
            true
        } catch (e: Exception) {
            Log.w(TAG, "configure $name ${s.width}x${s.height} failed: $e")
            // MediaCodec.createInputSurface: the app releases the Surface; a failed start() must not leak it.
            runCatching { surface?.release() }
            runCatching { c?.release() }
            false
        }
    }

    private fun attach(projection: MediaProjection, s: EncoderSizing.Size, dpi: Int): Boolean {
        val surface = inputSurface ?: return false
        return try {
            val vd = virtualDisplay
            if (vd != null && this.projection === projection) {
                vd.resize(s.width, s.height, dpi)
                vd.setSurface(surface)
            } else {
                runCatching { vd?.release() }
                // The MediaProjection.Callback is registered by MirrorController before any start reaches here.
                virtualDisplay = projection.createVirtualDisplay(
                    VIRTUAL_DISPLAY_NAME, s.width, s.height, dpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, handler,
                )
                this.projection = projection
            }
            virtualDisplay != null
        } catch (e: Exception) {
            Log.w(TAG, "virtual display failed: $e")
            false
        }
    }

    private fun stopCodec() {
        // Detaching the surface turns the virtual display "off" without releasing it (VirtualDisplay.setSurface).
        runCatching { virtualDisplay?.setSurface(null) }
        val c = codec
        codec = null
        if (c != null) {
            runCatching { c.stop() }
            runCatching { c.release() }
        }
        runCatching { inputSurface?.release() }
        inputSurface = null
        size = EncoderSizing.Size(0, 0)
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}     // surface input: never used

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (codec !== this@ScreenEncoder.codec) return                         // a released codec's late buffer
            try {
                val buf = codec.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    val pts = if (config) 0L else {
                        if (ptsOriginUs < 0) ptsOriginUs = info.presentationTimeUs
                        info.presentationTimeUs - ptsOriginUs
                    }
                    sink.output(config, key, pts, buf)
                    if (!config) recoveries = 0
                }
            } catch (e: IllegalStateException) {
                Log.w(TAG, "output buffer: $e")
            } finally {
                runCatching { codec.releaseOutputBuffer(index, false) }
            }
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            if (codec !== this@ScreenEncoder.codec) return
            Log.w(TAG, "codec error: $e")
            val again = lastStart
            if (again != null && recoveries < 1) {
                // PROTOCOL 14.1: an encoder error recovery starts a new stream (new HELLO). One try, then report.
                recoveries++
                startNow(again.third, again.first, again.second)
            } else {
                stopCodec()
                sink.failed("codec error $e")
            }
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "output format $format")
        }
    }
}
