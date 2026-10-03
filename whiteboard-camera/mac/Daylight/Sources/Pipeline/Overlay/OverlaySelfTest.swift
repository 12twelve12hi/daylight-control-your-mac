import CoreVideo
import DaylightKit
import Foundation
import Metal
import QuartzCore

/// The Presenter Overlay probes of `--self-test` (SPEC 6.7): compositor pixels with a synthetic mask, the mask
/// processor against the Kit formulas, a generous time budget, and a Vision probe that never fails the run.
/// The helpers are shared with the hosted tests in DaylightTests/Overlay.
enum OverlaySelfTest {
    /// Mask processing plus the overlay render's CPU encode on the synthetic frame. Generous on purpose: it catches
    /// pathologies (a CPU fallback per pixel, a stalled command buffer), not regressions of a few milliseconds.
    static let budgetMs: Double = 50
    /// The synthetic mask's size (the order of the fast Vision mask).
    static let maskWidth = 256
    static let maskHeight = 144

    static func run(device: MTLDevice?, report: SelfTest.Report) {
        guard let device = device else {
            report.note("overlay probes skipped: no Metal device")
            return
        }
        do {
            try renderProbes(device: device, report: report)
            try processorProbes(device: device, report: report)
        } catch {
            report.check("overlay: setup", false, "\(error)")
        }
        visionProbe(report: report)
    }

    // MARK: Shared helpers

    /// A mask over the whole camera frame: 1 where u < 0.5, 0 elsewhere (the left half of the central square is the
    /// "person", the right half background).
    static func splitMask(device: MTLDevice) -> MTLTexture? {
        var values = [Float](repeating: 0, count: maskWidth * maskHeight)
        for y in 0..<maskHeight {
            for x in 0..<maskWidth where (Double(x) + 0.5) / Double(maskWidth) < 0.5 {
                values[y * maskWidth + x] = 1
            }
        }
        return MaskProcessor.makeMaskTexture(device: device, width: maskWidth, height: maskHeight, values: values)
    }

    /// The camera pixel the cutout samples at output pixel (x, y).
    static func sourcePoint(_ cutout: OverlayLayout.Cutout, x: Int, y: Int, width: Int = 1920, height: Int = 1080) -> (x: Int, y: Int) {
        let fx = (Double(x) + 0.5 - cutout.dest.x) / cutout.dest.w
        let fy = (Double(y) + 0.5 - cutout.dest.y) / cutout.dest.h
        let u = cutout.uv.u0 + fx * (cutout.uv.u1 - cutout.uv.u0)
        let v = cutout.uv.v0 + fy * (cutout.uv.v1 - cutout.uv.v0)
        return (min(width - 1, max(0, Int(u * Double(width)))), min(height - 1, max(0, Int(v * Double(height)))))
    }

    /// Output pixel at fraction (fx, fy) of the cutout's dest rectangle.
    static func point(in cutout: OverlayLayout.Cutout, fx: Double, fy: Double) -> (x: Int, y: Int) {
        return (Int(cutout.dest.x + cutout.dest.w * fx), Int(cutout.dest.y + cutout.dest.h * fy))
    }

    /// The output x of the mask edge (u = 0.5) inside the cutout.
    static func edgeX(_ cutout: OverlayLayout.Cutout) -> Double {
        return cutout.dest.x + cutout.dest.w * (0.5 - cutout.uv.u0) / (cutout.uv.u1 - cutout.uv.u0)
    }

    /// The Overlay frame at progress `s` (portrait ink canvas).
    static func frame(progress s: Double, config: OverlayLayout.Config = .default) -> StudioLayout.Frame {
        return OverlayLayout.frame(progress: s, orientation: .portrait, canvasAspect: StudioLayout.portraitAspect, breath: 0, config: config)
    }

    /// The expected result of `MaskProcessor` on the CPU, from the Kit formulas: IIR against `previous` (nil: the
    /// first mask, taken as is), then the separable blur with clamped edges.
    static func reference(previous: [Float]?, current: [Float], width: Int, height: Int, smoothing: Double, feather: Int) -> (smoothed: [Float], blurred: [Float]) {
        var smoothed = current
        if let previous = previous {
            for i in 0..<current.count {
                smoothed[i] = Float(OverlayLayout.smoothed(previous: Double(previous[i]), new: Double(current[i]), smoothing: smoothing))
            }
        }
        let weights = OverlayLayout.featherWeights(radius: feather)
        let r = weights.count / 2
        func blur(_ src: [Float], dx: Int, dy: Int) -> [Float] {
            var out = [Float](repeating: 0, count: src.count)
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0
                    for i in -r...r {
                        let sx = min(max(x + dx * i, 0), width - 1)
                        let sy = min(max(y + dy * i, 0), height - 1)
                        sum += weights[i + r] * src[sy * width + sx]
                    }
                    out[y * width + x] = sum
                }
            }
            return out
        }
        return (smoothed, blur(blur(smoothed, dx: 1, dy: 0), dx: 0, dy: 1))
    }

    // MARK: Probes

    private static func renderProbes(device: MTLDevice, report: SelfTest.Report) throws {
        let compositor = try Compositor(device: device)
        let surfaces = try CanvasSurfaces(device: device)
        let pool = try OutputPool()
        guard let presenter = SelfTest.gradientBuffer(width: 1920, height: 1080), let mask = splitMask(device: device) else {
            report.check("overlay: synthetic buffers", false)
            return
        }
        let input = Compositor.OverlayInput(mask: mask)
        func render(_ frame: StudioLayout.Frame) -> CVPixelBuffer? {
            guard let target = pool.acquire() else { return nil }
            _ = compositor.renderSync(Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: frame, overlay: input), into: target)
            pool.release(target)
            return target
        }
        // s = 0: pixel-identical to passthrough.
        if let target = render(frame(progress: 0)) {
            let same = [(0, 0), (960, 540), (1919, 1079)].allSatisfy { SelfTest.close(SelfTest.pixel(target, $0.0, $0.1), SelfTest.pixel(presenter, $0.0, $0.1), tolerance: 1) }
            report.check("overlay s=0 equals the camera picture", same)
        }
        // s = 1, defaults (bottom right): matte left half shows the presenter, the clear right half the cream.
        let full = frame(progress: 1)
        if let target = render(full), let cutout = full.overlay {
            let left = point(in: cutout, fx: 0.25, fy: 0.5)
            let source = sourcePoint(cutout, x: left.x, y: left.y)
            let right = point(in: cutout, fx: 0.75, fy: 0.5)
            report.check("overlay s=1 matte (\(left.x), \(left.y)) = source (\(source.x), \(source.y))", SelfTest.close(SelfTest.pixel(target, left.x, left.y), SelfTest.pixel(presenter, source.x, source.y), tolerance: 3), SelfTest.describe(SelfTest.pixel(target, left.x, left.y)))
            report.check("overlay s=1 clear (\(right.x), \(right.y)) is cream", SelfTest.matches(SelfTest.pixel(target, right.x, right.y), Tokens.surfaceCream), SelfTest.describe(SelfTest.pixel(target, right.x, right.y)))
            report.check("overlay s=1 paper at (960, 540)", SelfTest.matches(SelfTest.pixel(target, 960, 540), Tokens.paperBg), SelfTest.describe(SelfTest.pixel(target, 960, 540)))
        }
        // Halo: just right of the mask edge the amber ring shows.
        let haloFrame = frame(progress: 1, config: OverlayLayout.Config(halo: true))
        if let target = render(haloFrame), let cutout = haloFrame.overlay {
            let x = Int(edgeX(cutout).rounded(.up)) + 4
            let y = point(in: cutout, fx: 0.5, fy: 0.5).y
            report.check("overlay halo amber at (\(x), \(y))", SelfTest.matches(SelfTest.pixel(target, x, y), OverlayLayout.haloColor, tolerance: 40), SelfTest.describe(SelfTest.pixel(target, x, y)))
        }
        // Budget: a mask processed plus one overlay render encoded.
        let processor = try MaskProcessor(device: device, smoothing: 0.6, feather: 2)
        _ = try processor.process(source: mask, at: 0, coverage: 0.5)
        let start = CACurrentMediaTime()
        let output = try processor.process(source: mask, at: 0, coverage: 0.5)
        if let target = pool.acquire() {
            let done = DispatchSemaphore(value: 0)
            let inputs = Compositor.Inputs(presenter: presenter, canvas: .layers(surfaces), frame: full, overlay: Compositor.OverlayInput(mask: output.texture))
            compositor.render(inputs, into: target) { _ in done.signal() }
            let ms = (CACurrentMediaTime() - start) * 1000
            _ = done.wait(timeout: .now() + 5)
            pool.release(target)
            report.check(String(format: "overlay mask processing + render encode %.2f ms under %.0f ms", ms, budgetMs), ms < budgetMs)
        }
    }

    private static func processorProbes(device: MTLDevice, report: SelfTest.Report) throws {
        let width = 8, height = 4
        var first = [Float](repeating: 0, count: width * height)
        var second = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                first[y * width + x] = x < 4 ? 1 : 0
                second[y * width + x] = x < 6 ? 1 : 0
            }
        }
        guard let a = MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: first),
              let b = MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: second) else {
            report.check("overlay processor: synthetic masks", false)
            return
        }
        let processor = try MaskProcessor(device: device, smoothing: 0.5, feather: 1)
        _ = try processor.process(source: a, at: 0, coverage: 0.5)
        let output = try processor.process(source: b, at: 0.033, coverage: 0.75)
        guard let values = MaskProcessor.readBack(output.texture, device: device) else {
            report.check("overlay processor: read back", false)
            return
        }
        let expected = reference(previous: first, current: second, width: width, height: height, smoothing: 0.5, feather: 1).blurred
        let worst = zip(values, expected).map { abs($0 - $1) }.max() ?? 1
        report.check(String(format: "overlay processor IIR + blur match the Kit formulas (max error %.4f)", worst), worst < 0.01)
    }

    /// Vision on a synthetic frame: a throw, a missing result or a timeout is a note, never a failure (a runner may
    /// have no person segmentation, and a gradient has no person in it).
    private static func visionProbe(report: SelfTest.Report) {
        guard let frame = SelfTest.gradientBuffer(width: 1920, height: 1080) else {
            report.note("overlay vision probe skipped: no synthetic frame")
            return
        }
        let result = Locked<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do {
                let mask = try VisionPersonEngine().mask(for: frame, quality: .fast)
                text = String(format: "overlay vision probe: mask %ldx%ld coverage %.3f", CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(mask), PersonSegmenter.coverage(of: mask))
            } catch {
                text = "overlay vision probe skipped: \(error)"
            }
            result.withLock { $0 = text }
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            report.note("overlay vision probe skipped: no answer within 10 s")
        } else {
            report.note(result.withLock { $0 } ?? "overlay vision probe skipped: no result")
        }
    }
}
