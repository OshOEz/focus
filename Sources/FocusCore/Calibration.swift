import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    let n = s.count
    guard n > 0 else { return .nan }
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Everything learned about one display in one setup (spec §5).
public struct DisplayCalibration: Codable, Sendable, Equatable {
    public static let maxLearned = 200
    public static let errorWindow = 30
    /// 15 % of the unit-square diagonal.
    public static let errorThreshold = 0.15 * 2.0.squareRoot()

    public var pose: PoseFeature
    public var calibrationPoints: [CalibrationPoint]
    public var learnedPoints: [CalibrationPoint] = []
    public var recentErrors: [Double] = []

    // ponytail: rebuilt on every access (O(n³), n ≤ 205); callers on a per-frame path must cache it (FocusEngine does).
    public var map: RBFMap? { RBFMap(points: calibrationPoints + learnedPoints) }

    public var needsRecalibration: Bool {
        recentErrors.count >= 10 && recentErrors.reduce(0, +) / Double(recentErrors.count) > Self.errorThreshold
    }

    /// Adds a click-derived sample; the error is measured against the model *before* learning it.
    /// Non-finite points (NaN/inf input or target) are ignored: they'd poison the RBF solve and
    /// silently disable the map (issue #4).
    public mutating func learn(_ p: CalibrationPoint) {
        guard p.input.x.isFinite, p.input.y.isFinite, p.target.x.isFinite, p.target.y.isFinite else { return }
        if let m = map {
            let q = m.map(p.input)
            recentErrors.append(Double(hypot(q.x - p.target.x, q.y - p.target.y)))
            if recentErrors.count > Self.errorWindow { recentErrors.removeFirst(recentErrors.count - Self.errorWindow) }
        }
        learnedPoints.append(p)
        if learnedPoints.count > Self.maxLearned { learnedPoints.removeFirst(learnedPoints.count - Self.maxLearned) }
    }
}

public enum CalibrationBuilder {
    static let minSamplesPerTarget = 5

    /// `targets`: each on-screen target (local [0,1]) with the samples collected while it was shown.
    public static func build(targets: [(target: CGPoint, samples: [GazeSample])], minConfidence: Double) -> DisplayCalibration? {
        var points: [CalibrationPoint] = []
        var poses: [PoseFeature] = []
        for (target, samples) in targets {
            let good = samples.filter { $0.confidence >= minConfidence && $0.raw.x.isFinite && $0.raw.y.isFinite }
            guard good.count >= minSamplesPerTarget else { continue }
            points.append(CalibrationPoint(
                input: CGPoint(x: median(good.map { $0.raw.x }), y: median(good.map { $0.raw.y })), target: target))
            poses += good.map(\.pose)
        }
        guard points.count >= 3 else { return nil }
        let pose = PoseFeature(yaw: median(poses.map(\.yaw)), pitch: median(poses.map(\.pitch)),
                               faceX: median(poses.map(\.faceX)), faceY: median(poses.map(\.faceY)))
        return DisplayCalibration(pose: pose, calibrationPoints: points)
    }
}
