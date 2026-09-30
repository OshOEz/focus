import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One calibration session: screen by screen, dot by dot. It is pure and takes the clock as a parameter,
/// so the AppKit window only draws `phase`/`dot(at:)` and forwards keys, samples and ticks.
public struct CalibrationRun: Sendable {
    public struct Screen: Sendable, Equatable {
        public var key: String
        /// Display-local [0,1], y down, from CalibrationLayout (9-dot grid first, then shared-edge dots). ≥ 3 targets.
        public var targets: [CGPoint]
        public init(key: String, targets: [CGPoint]) { self.key = key; self.targets = targets }
    }

    public enum Failure: Equatable, Sendable { case noFace, screensLookedSame }

    public enum Phase: Equatable, Sendable {
        case ready(screen: Int)                               // waiting for Space
        case dot(screen: Int, index: Int, start: Double)      // `start` = when this dot began to travel
        case failed(screen: Int, Failure)                     // Space retries, Esc cancels
        case finished
        case cancelled
    }

    /// Dot timing: ~0.6 s travel lets the eyes land, 1.0 s hold collects enough frames for a stable median.
    /// 9 dots ≈ 15 s per screen, ~20 s with the shared-edge dots: short enough to redo without friction.
    public static let travel = 0.6
    public static let hold = 1.0
    /// Two screens whose median poses are closer than this (≈ 4.6° if only yaw differs) can't be told apart
    /// by the screen classifier. From a normal seat, neighbouring monitors are ≥ 15° apart.
    public static let minScreenSeparation = 0.08

    public let screens: [Screen]
    /// Calibrated displays that are not part of this run: a recalibrated screen must stay distinct from them too.
    public let others: [String: PoseFeature]
    public let minConfidence: Double
    public private(set) var phase: Phase
    public private(set) var results: [String: DisplayCalibration] = [:]
    private var collected: [[GazeSample]] = []

    public init(screens: [Screen], others: [String: PoseFeature] = [:], minConfidence: Double) {
        self.screens = screens
        self.others = others
        self.minConfidence = minConfidence
        phase = screens.isEmpty ? .finished : .ready(screen: 0)
    }

    public mutating func pressSpace(at now: Double) {
        switch phase {
        case .ready(let i), .failed(let i, .noFace): begin(i, at: now)
        case .failed(_, .screensLookedSame): results = [:]; begin(0, at: now)
        default: break
        }
    }

    public mutating func pressEscape() {
        guard phase != .finished else { return }
        phase = .cancelled
        results = [:]
    }

    /// Only samples captured during a dot's hold count: during travel the eyes are still catching up, and
    /// anything before Space was captured while the user read the instructions (host-clock times).
    public mutating func add(_ s: GazeSample) {
        guard case .dot(_, let k, let start) = phase,
              s.time >= start + Self.travel, s.time < start + Self.travel + Self.hold else { return }
        collected[k].append(s)
    }

    public mutating func tick(at now: Double) {
        guard case .dot(let i, let k, let start) = phase, now >= start + Self.travel + Self.hold else { return }
        // The next dot starts at `now`, not at the ideal boundary: after a stall (app busy) it still gets a full travel + hold.
        if k + 1 < screens[i].targets.count { phase = .dot(screen: i, index: k + 1, start: now); return }
        finish(i)
    }

    /// Where to draw the dot (local [0,1], y down) and how much of its hold has elapsed; nil when no dot is shown.
    public func dot(at now: Double) -> (point: CGPoint, progress: Double)? {
        guard case .dot(let i, let k, let start) = phase else { return nil }
        let targets = screens[i].targets
        let t = now - start
        guard t >= Self.travel else {
            let from = k > 0 ? targets[k - 1] : targets[k]
            let u = max(t, 0) / Self.travel
            let e = u * u * (3 - 2 * u)   // smoothstep: eases in and out like a pointer, easy to follow
            return (CGPoint(x: from.x + (targets[k].x - from.x) * e, y: from.y + (targets[k].y - from.y) * e), 0)
        }
        return (targets[k], min((t - Self.travel) / Self.hold, 1))
    }

    private mutating func begin(_ i: Int, at now: Double) {
        collected = Array(repeating: [], count: screens[i].targets.count)
        phase = .dot(screen: i, index: 0, start: now)
    }

    private mutating func finish(_ i: Int) {
        let screen = screens[i]
        let pairs = zip(screen.targets, collected).map { (target: $0.0, samples: $0.1) }
        guard let cal = CalibrationBuilder.build(targets: pairs, minConfidence: minConfidence) else {
            phase = .failed(screen: i, .noFace)
            return
        }
        let known = others.filter { $0.key != screen.key }.map(\.value)
            + results.filter { $0.key != screen.key }.map(\.value.pose)
        if known.contains(where: { $0.distance(to: cal.pose) < Self.minScreenSeparation }) {
            phase = .failed(screen: i, .screensLookedSame)
            return
        }
        results[screen.key] = cal
        phase = i + 1 < screens.count ? .ready(screen: i + 1) : .finished
    }
}
