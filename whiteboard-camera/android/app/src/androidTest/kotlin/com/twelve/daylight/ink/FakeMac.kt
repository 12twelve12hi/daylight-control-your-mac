package com.twelve.daylight.ink

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A tiny Mac for the instrumented tests: `ws://127.0.0.1:<port>/ink` speaking just enough of PROTOCOL 1 and 8.
 * RFC 6455 by hand on a ServerSocket (no dependency): the upgrade echoes `solstream.v1`, client frames are unmasked,
 * pings are answered, every binary message is kept in [received]. A HANDSHAKE (0x0001) is answered with [ack] then
 * [state] (the golden vectors by default). `POST /api/facts` (PROTOCOL 15) is answered 200 and its body kept.
 */
class FakeMac(private val ack: ByteArray, private val state: ByteArray) : Closeable {
    companion object {
        const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        const val SUBPROTOCOL = "solstream.v1"

        fun acceptKey(key: String): String {
            val sha1 = MessageDigest.getInstance("SHA-1").digest((key.trim() + GUID).toByteArray(Charsets.ISO_8859_1))
            return Base64.getEncoder().encodeToString(sha1)
        }

        fun opcode(frame: ByteArray): Int =
            if (frame.size < 16) -1 else ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN).getShort(2).toInt() and 0xFFFF
    }

    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = server.localPort
    val host: String get() = "127.0.0.1:$port"

    /** Binary messages from the tablet, in arrival order (all connections). */
    val received = CopyOnWriteArrayList<ByteArray>()
    /** HANDSHAKE names (`role;clientId;label`). */
    val handshakeNames = CopyOnWriteArrayList<String>()
    /** Subprotocol header of every upgrade request. */
    val offeredProtocols = CopyOnWriteArrayList<String>()
    val factsBodies = CopyOnWriteArrayList<String>()
    private val sockets = CopyOnWriteArrayList<Socket>()
    @Volatile private var closed = false

    init {
        val t = Thread({ acceptLoop() }, "fake-mac-accept")
        t.isDaemon = true
        t.start()
    }

    fun opcodes(): List<Int> = received.map { opcode(it) }

    override fun close() {
        closed = true
        runCatching { server.close() }
        for (s in sockets) runCatching { s.close() }
    }

    private fun acceptLoop() {
        while (!closed) {
            val s = try { server.accept() } catch (e: IOException) { return }
            sockets.add(s)
            val t = Thread({ runCatching { serve(s) }; runCatching { s.close() } }, "fake-mac-conn")
            t.isDaemon = true
            t.start()
        }
    }

    private fun readLine(input: DataInputStream): String? {
        val line = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return if (line.size() == 0) null else line.toString("ISO-8859-1")
            if (b == '\n'.code) return line.toString("ISO-8859-1").trimEnd('\r')
            line.write(b)
        }
    }

    private fun serve(s: Socket) {
        s.tcpNoDelay = true
        val input = DataInputStream(BufferedInputStream(s.getInputStream()))
        val out = s.getOutputStream()
        val request = readLine(input) ?: return
        val headers = HashMap<String, String>()
        while (true) {
            val line = readLine(input) ?: return
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        val parts = request.split(" ")
        val method = parts.getOrElse(0) { "" }
        val path = parts.getOrElse(1) { "" }
        if (method == "GET" && path == "/ink" && headers["upgrade"].equals("websocket", ignoreCase = true)) {
            val key = headers["sec-websocket-key"] ?: return
            offeredProtocols.add(headers["sec-websocket-protocol"] ?: "")
            val response = "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: ${acceptKey(key)}\r\n" +
                "Sec-WebSocket-Protocol: $SUBPROTOCOL\r\n\r\n"
            out.write(response.toByteArray(Charsets.ISO_8859_1))
            out.flush()
            frames(input, out)
        } else if (method == "POST" && path == "/api/facts") {
            val length = headers["content-length"]?.toIntOrNull() ?: 0
            val body = ByteArray(length)
            input.readFully(body)
            factsBodies.add(String(body, Charsets.UTF_8))
            out.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            out.flush()
        } else {
            out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            out.flush()
        }
    }

    private fun frames(input: DataInputStream, out: OutputStream) {
        while (!closed) {
            val b0 = input.read()
            if (b0 < 0) return
            val b1 = input.readUnsignedByte()
            val op = b0 and 0x0F
            var len = (b1 and 0x7F).toLong()
            if (len == 126L) {
                len = input.readUnsignedShort().toLong()
            } else if (len == 127L) {
                len = input.readLong()
            }
            if (len < 0 || len > 16L * 1024 * 1024) return
            val mask = if ((b1 and 0x80) != 0) ByteArray(4).also { input.readFully(it) } else null
            val payload = ByteArray(len.toInt())
            input.readFully(payload)
            if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
            when (op) {
                0x2 -> onBinary(payload, out)
                0x8 -> { send(out, 0x8, payload.copyOf(minOf(payload.size, 2))); return }
                0x9 -> send(out, 0xA, payload)
                else -> {}          // text, pong, continuation: the tablet sends none that matter here
            }
        }
    }

    private fun onBinary(payload: ByteArray, out: OutputStream) {
        received.add(payload)
        if (opcode(payload) == 0x0001 && payload.size >= 30) {
            val b = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
            val nameLen = b.getShort(28).toInt() and 0xFFFF
            if (30 + nameLen <= payload.size) handshakeNames.add(String(payload, 30, nameLen, Charsets.UTF_8))
            send(out, 0x2, ack)
            send(out, 0x2, state)
        }
    }

    /** One unmasked, unfragmented server frame. */
    fun send(out: OutputStream, opcode: Int, payload: ByteArray) {
        synchronized(out) {
            out.write(0x80 or opcode)
            when {
                payload.size < 126 -> out.write(payload.size)
                payload.size <= 0xFFFF -> { out.write(126); out.write(payload.size shr 8); out.write(payload.size and 0xFF) }
                else -> { out.write(127); for (i in 7 downTo 0) out.write(((payload.size.toLong() shr (8 * i)) and 0xFF).toInt()) }
            }
            out.write(payload)
            out.flush()
        }
    }
}
