import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import QuartzCore
import GazeKit
import FocusCore

/// Group 3: the real `GazeTracker` (FaceMesh → head pose → BlazeGaze) on a still photo, never the
/// camera — CoreImage transforms (shift/scale/roll/perspective) stand in for head motion so the
/// bench stays unattended (no Camera TCC prompt). See docs/wiki/Benches.md for the rules.
/// `@MainActor`: `main.swift`'s group table already runs every group there, and it lets `initError`
/// be a plain static var and `EngineBench.percentile` be reused directly.
@MainActor
enum VisionBench {
    static let group = BenchResult.groupNames[3]!
    static let width = 1280, height = 720
    static let canvas = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
    static let center = CGPoint(x: canvas.midX, y: canvas.midY)
    static let ciContext = CIContext()

    /// Set by `newTracker()` when `GazeTracker.init()` throws, so every check that follows reports
    /// the same failure instead of crashing (model files missing from the checkout, say).
    static var initError: String?

    static func run(fixtures: String) -> [BenchResult] {
        let path = "\(fixtures)/portrait.jpg"
        guard let source = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
            return [.check(group, "portrait.jpg", false, rule: "file exists", reason: "portrait.jpg not found at \(path)")]
        }
        let base = centered(source)
        return [frontalCheck(base), shiftCheck(base), scaleCheck(base), rollCheck(base),
                yawFollowsTurnCheck(base), noFaceCheck(), msPerFrameCheck(base)]
    }

    // MARK: - Frame construction

    /// `image` composited over a mid-grey 1280×720 canvas, rendered into a fresh BGRA pixel buffer
    /// (the shape `GazeTracker.process` expects from the camera).
    static func frame(_ image: CIImage) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
        ciContext.render(image.composited(over: grey), to: pb!, bounds: canvas, colorSpace: nil)
        return pb!
    }

    /// A pixel buffer of seeded random bytes (deterministic "no face" stand-in for sensor noise) —
    /// reuses `SplitMix64` (`Desk.swift`) rather than `CIRandomGenerator`, whose output isn't a
    /// documented, reproducible seed.
    static func noiseFrame(seed: UInt64) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var rng = SplitMix64(state: seed)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let total = CVPixelBufferGetBytesPerRow(buffer) * height
        for i in 0..<total { base[i] = UInt8(truncatingIfNeeded: rng.next()) }
        return buffer
    }

    // MARK: - Geometry (portrait.jpg → poses, CoreImage only)

    /// `image` scaled to 80 % of the canvas height and centred on it.
    static func centered(_ image: CIImage) -> CIImage {
        let scale = (0.8 * canvas.height) / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: center.x - e.midX, y: center.y - e.midY))
    }

    /// `t` applied about the canvas centre instead of the origin.
    static func around(_ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(t)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    static func scaled(_ image: CIImage, _ factor: Double) -> CIImage {
        image.transformed(by: around(CGAffineTransform(scaleX: factor, y: factor)))
    }

    static func rotated(_ image: CIImage, degrees: Double) -> CIImage {
        image.transformed(by: around(CGAffineTransform(rotationAngle: degrees * .pi / 180)))
    }

    /// Approximates a head turn: `CIPerspectiveTransform` shrinks the right edge (`fraction > 0`) or
    /// the left edge (`fraction < 0`) by `|fraction|` of the image width — a turn away from that side.
    static func headTurn(_ image: CIImage, _ fraction: Double) -> CIImage {
        guard fraction != 0 else { return image }
        let e = image.extent, dx = e.width * abs(fraction)
        let f = CIFilter(name: "CIPerspectiveTransform")!
        f.setValue(image, forKey: kCIInputImageKey)
        let (nearTop, nearBottom, farTop, farBottom) = fraction > 0
            ? (CGPoint(x: e.maxX - dx, y: e.maxY), CGPoint(x: e.maxX - dx, y: e.minY), CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.minX, y: e.minY))
            : (CGPoint(x: e.minX + dx, y: e.maxY), CGPoint(x: e.minX + dx, y: e.minY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.maxX, y: e.minY))
        let (topLeft, topRight, bottomLeft, bottomRight) = fraction > 0
            ? (farTop, nearTop, farBottom, nearBottom) : (nearTop, farTop, nearBottom, farBottom)
        f.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        f.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        return f.outputImage ?? image
    }

    // MARK: - Tracking

    static func newTracker() -> GazeTracker? {
        do { return try GazeTracker() } catch { initError = "\(error)"; return nil }
    }

    /// A fresh tracker (the landmarker tracks state across frames — a fresh one per case avoids
    /// carrying a face over), the same pixel buffer processed 5 times, last sample returned.
    static func measure(_ pixelBuffer: CVPixelBuffer) -> GazeSample? {
        guard let tracker = newTracker() else { return nil }
        var last = GazeSample.noFace(at: 0)
        for i in 0..<5 { last = tracker.process(pixelBuffer: pixelBuffer, time: Double(i)) }
        return last
    }

    static func measure(_ image: CIImage) -> GazeSample? { measure(frame(image)) }

    /// NaN in a metric would make the whole JSON array unencodable (`Report`'s convention: -1 for "never").
    static func finite(_ x: Double) -> Double { x.isFinite ? x : -1 }

    static func failed(_ name: String, rule: String) -> BenchResult {
        .check(group, name, false, rule: rule, reason: initError ?? "GazeTracker() failed")
    }

    // MARK: - Checks

    static func frontalCheck(_ base: CIImage) -> BenchResult {
        let rule = "confidence ≥ 0.5, raw finite, |yaw| < 0.3, |pitch| < 0.4"
        guard let s = measure(base) else { return failed("frontal", rule: rule) }
        let ok = s.confidence >= 0.5 && s.raw.x.isFinite && s.raw.y.isFinite && abs(s.pose.yaw) < 0.3 && abs(s.pose.pitch) < 0.4
        return .check(group, "frontal", ok, rule: rule,
                      metrics: ["confidence": s.confidence, "yaw": finite(s.pose.yaw), "pitch": finite(s.pose.pitch), "faceX": finite(s.pose.faceX)],
                      reason: "confidence \(s.confidence), yaw \(s.pose.yaw), pitch \(s.pose.pitch)")
    }

    /// Translate ±160 px in x: `faceX` must move the same way, pose (yaw) must not — a pure
    /// translation isn't a head turn.
    static func shiftCheck(_ base: CIImage) -> BenchResult {
        let rule = "found in all three, faceX strictly increasing with the shift, |Δyaw| < 0.1 vs frontal"
        guard let frontal = measure(base) else { return failed("shift", rule: rule) }
        var samples: [GazeSample] = []
        for dx in [-160.0, 0.0, 160.0] {
            guard let s = measure(base.transformed(by: CGAffineTransform(translationX: dx, y: 0))) else { return failed("shift", rule: rule) }
            samples.append(s)
        }
        let xs = samples.map(\.pose.faceX)
        let increasing = zip(xs, xs.dropFirst()).allSatisfy(<)
        let dyaw = samples.map { abs($0.pose.yaw - frontal.pose.yaw) }.max() ?? .infinity
        let ok = samples.allSatisfy(\.hasFace) && increasing && dyaw < 0.1
        return .check(group, "shift", ok, rule: rule,
                      metrics: ["faceX_left": finite(xs[0]), "faceX_center": finite(xs[1]), "faceX_right": finite(xs[2])],
                      reason: "faceX \(xs), Δyaw max \(dyaw)")
    }

    /// Scale 0.8× and 1.2× about the centre: distance from the camera changes, head pose shouldn't.
    static func scaleCheck(_ base: CIImage) -> BenchResult {
        let rule = "found, |Δyaw| < 0.1, |Δpitch| < 0.1 vs frontal (both 0.8× and 1.2×)"
        guard let frontal = measure(base) else { return failed("scale", rule: rule) }
        var ok = true, metrics: [String: Double] = [:], reasons: [String] = []
        for factor in [0.8, 1.2] {
            guard let s = measure(scaled(base, factor)) else { return failed("scale", rule: rule) }
            let dyaw = abs(s.pose.yaw - frontal.pose.yaw), dpitch = abs(s.pose.pitch - frontal.pose.pitch)
            ok = ok && s.hasFace && dyaw < 0.1 && dpitch < 0.1
            metrics["yaw_\(factor)x"] = finite(s.pose.yaw); metrics["pitch_\(factor)x"] = finite(s.pose.pitch)
            reasons.append("\(factor)×: found \(s.hasFace) Δyaw \(dyaw) Δpitch \(dpitch)")
        }
        return .check(group, "scale", ok, rule: rule, metrics: metrics, reason: reasons.joined(separator: "; "))
    }

    /// Rotate ±10° about the centre (camera roll, e.g. a tilted laptop): yaw shouldn't follow it.
    static func rollCheck(_ base: CIImage) -> BenchResult {
        let rule = "found, |Δyaw| < 0.15 vs frontal (both ±10°)"
        guard let frontal = measure(base) else { return failed("roll", rule: rule) }
        var ok = true, metrics: [String: Double] = [:], reasons: [String] = []
        for degrees in [-10.0, 10.0] {
            guard let s = measure(rotated(base, degrees: degrees)) else { return failed("roll", rule: rule) }
            let dyaw = abs(s.pose.yaw - frontal.pose.yaw)
            ok = ok && s.hasFace && dyaw < 0.15
            metrics["yaw_\(degrees)deg"] = finite(s.pose.yaw)
            reasons.append("\(degrees)°: found \(s.hasFace) Δyaw \(dyaw)")
        }
        return .check(group, "roll", ok, rule: rule, metrics: metrics, reason: reasons.joined(separator: "; "))
    }

    /// The architecture's "pose sign monotonicity" can't be proven on a still photo: a 2-D
    /// perspective skew is not a head turn (no depth cue moves), so yaw stays at noise level.
    /// The row is skipped with the measured yaws kept for the record; the real check is live
    /// ("turn your head left/right: yaw changes sign", TESTING.md / scripts/morning-check.sh).
    static func yawFollowsTurnCheck(_ base: CIImage) -> BenchResult {
        let reason = "a still photo warped in 2-D cannot turn a head — checked live in scripts/morning-check.sh"
        let fractions = [0.2, 0.1, 0.0, -0.1, -0.2]
        var yaws: [Double] = []
        for f in fractions {
            guard let s = measure(headTurn(base, f)), s.hasFace else {
                return .skip(group, "yaw-follows-turn", "\(reason) (no face at fraction \(f))")
            }
            yaws.append(s.pose.yaw)
        }
        return BenchResult(group: group, name: "yaw-follows-turn", status: .skip,
                           reason: "\(reason); yaws \(yaws.map { String(format: "%.3f", $0) }) at fractions \(fractions)",
                           metrics: Dictionary(uniqueKeysWithValues: fractions.enumerated().map { ("yaw_\($0.offset)", finite(yaws[$0.offset])) }))
    }

    /// A black frame and seeded uniform noise: neither has a face.
    static func noFaceCheck() -> BenchResult {
        let rule = "confidence == 0, raw NaN (both black and noise)"
        let black = frame(CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas))
        guard let blackSample = measure(black), let noiseSample = measure(noiseFrame(seed: 0x5EED)) else {
            return failed("no-face", rule: rule)
        }
        let ok = blackSample.confidence == 0 && blackSample.raw.x.isNaN && blackSample.raw.y.isNaN
            && noiseSample.confidence == 0 && noiseSample.raw.x.isNaN && noiseSample.raw.y.isNaN
        return .check(group, "no-face", ok, rule: rule,
                      metrics: ["black_confidence": blackSample.confidence, "noise_confidence": noiseSample.confidence],
                      reason: "black confidence \(blackSample.confidence), noise confidence \(noiseSample.confidence)")
    }

    /// One tracker, 5 warm-up calls, 60 timed calls. Debug builds skip: unoptimized CoreML/Accelerate
    /// code is not representative of the shipped app (architecture target: < 20 ms; 15 fps camera
    /// gives one frame every 67 ms).
    static func msPerFrameCheck(_ base: CIImage) -> BenchResult {
        let rule = "median_ms < 20"
        #if DEBUG
        return .skip(group, "ms-per-frame", "debug build: timings need -c release")
        #else
        guard let tracker = newTracker() else { return failed("ms-per-frame", rule: rule) }
        let pb = frame(base)
        for _ in 0..<5 { _ = tracker.process(pixelBuffer: pb, time: 0) }
        var ms: [Double] = []
        for _ in 0..<60 {
            let start = CACurrentMediaTime()
            _ = tracker.process(pixelBuffer: pb, time: 0)
            ms.append((CACurrentMediaTime() - start) * 1000)
        }
        let median = EngineBench.percentile(ms, 0.5), p95 = EngineBench.percentile(ms, 0.95)
        return .check(group, "ms-per-frame", median < 20, rule: rule, metrics: ["median_ms": median, "p95_ms": p95],
                      reason: "median \(median) ms, p95 \(p95) ms")
        #endif
    }
}
