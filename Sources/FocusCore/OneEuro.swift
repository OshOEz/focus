import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 1€ filter (Casiez, Roussel & Vogel, CHI 2012): a first-order low-pass whose cutoff rises
/// with the signal's speed, so a still head is smoothed hard (no jitter) and a turning head is
/// followed with little lag. Focus runs it on yaw, pitch, eye and face.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double        // Hz, smoothing at rest
    public var beta: Double             // extra cutoff (Hz) per unit/s of speed
    public var derivativeCutoff: Double // Hz, smoothing of the speed estimate itself
    private var last: Double?
    private var speed = 0.0
    private var lastTime = 0.0

    public init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff; self.beta = beta; self.derivativeCutoff = derivativeCutoff
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        1 / (1 + 1 / (2 * .pi * cutoff) / dt)
    }

    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let prev = last else { last = value; lastTime = time; speed = 0; return value }
        let dt = time - lastTime
        guard dt > 0 else { return prev }   // duplicate or out-of-order timestamp
        speed += Self.alpha(cutoff: derivativeCutoff, dt: dt) * ((value - prev) / dt - speed)
        let out = prev + Self.alpha(cutoff: minCutoff + beta * abs(speed), dt: dt) * (value - prev)
        last = out; lastTime = time
        return out
    }

    public mutating func reset() { last = nil }
}

/// Smooths yaw, pitch, face position and the raw gaze point of consecutive face samples.
/// Defaults are starting values for 15 fps (radians for pose, [0,1] for face, BlazeGaze units
/// for gaze); bench group 2 measures the latency they cost. They are knobs, not truths.
public struct GazeSmoother: Sendable {
    /// Longer than this without a face sample and the filters restart: bridging the gap would
    /// drag the old pose into the new one (the user may have turned while out of view).
    public static let maxGap = 0.5
    private var filters: [OneEuroFilter]
    private var lastTime = -Double.infinity

    public init(poseCutoff: Double = 1.0, poseBeta: Double = 1.5, faceCutoff: Double = 1.0, faceBeta: Double = 2.0,
                gazeCutoff: Double = 0.7, gazeBeta: Double = 1.0) {
        filters = [OneEuroFilter(minCutoff: poseCutoff, beta: poseBeta), OneEuroFilter(minCutoff: poseCutoff, beta: poseBeta),
                   OneEuroFilter(minCutoff: faceCutoff, beta: faceBeta), OneEuroFilter(minCutoff: faceCutoff, beta: faceBeta),
                   OneEuroFilter(minCutoff: gazeCutoff, beta: gazeBeta), OneEuroFilter(minCutoff: gazeCutoff, beta: gazeBeta)]
    }

    /// Non-face samples (no face, NaN pose or gaze) pass through unchanged and reset the filters,
    /// so a NaN never enters a filter's state.
    public mutating func smooth(_ s: GazeSample) -> GazeSample {
        guard s.hasFace else { reset(); return s }
        if s.time - lastTime > Self.maxGap { reset() }
        lastTime = s.time
        let t = s.time
        var out = s
        out.pose = PoseFeature(yaw: filters[0].filter(s.pose.yaw, at: t), pitch: filters[1].filter(s.pose.pitch, at: t),
                               faceX: filters[2].filter(s.pose.faceX, at: t), faceY: filters[3].filter(s.pose.faceY, at: t))
        out.raw = CGPoint(x: filters[4].filter(Double(s.raw.x), at: t), y: filters[5].filter(Double(s.raw.y), at: t))
        return out
    }

    public mutating func reset() {
        for i in filters.indices { filters[i].reset() }
        lastTime = -.infinity
    }
}
