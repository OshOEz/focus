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

/// Everything learned about one display in one setup.
public struct DisplayCalibration: Codable, Sendable, Equatable {
    public static let maxLearned = 200
    public static let errorWindow = 30
    /// 15 % of the unit-square diagonal.
    public static let errorThreshold = 0.15 * 2.0.squareRoot()

    public var pose: PoseFeature
    public var calibrationPoints: [CalibrationPoint]
    /// Median head pose at each calibration dot: the "cloud" whose facing edge places the
    /// screen boundary (ScreenClassifier). Empty for calibrations saved before edge dots existed.
    public var dotPoses: [PoseFeature] = []
    public var learnedPoints: [CalibrationPoint] = []
    public var recentErrors: [Double] = []

    public init(pose: PoseFeature, calibrationPoints: [CalibrationPoint], dotPoses: [PoseFeature] = [],
                learnedPoints: [CalibrationPoint] = [], recentErrors: [Double] = []) {
        self.pose = pose; self.calibrationPoints = calibrationPoints; self.dotPoses = dotPoses
        self.learnedPoints = learnedPoints; self.recentErrors = recentErrors
    }

    // ponytail: rebuilt on every access (O(n³), n ≤ 205); callers on a per-frame path must cache it (FocusEngine does).
    public var map: RBFMap? { RBFMap(points: calibrationPoints + learnedPoints) }

    public var needsRecalibration: Bool {
        recentErrors.count >= 10 && recentErrors.reduce(0, +) / Double(recentErrors.count) > Self.errorThreshold
    }

    /// Adds a click-derived sample; the error is measured against the model *before* learning it.
    /// Non-finite points (NaN/inf input or target) are ignored: they'd poison the RBF solve and
    /// silently disable the map.
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

extension DisplayCalibration {
    /// Pose and dots are required (without them the calibration is useless and the file should be
    /// quarantined); everything added since the first format is optional so older setups keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pose: try c.decode(PoseFeature.self, forKey: .pose),
                  calibrationPoints: try c.decode([CalibrationPoint].self, forKey: .calibrationPoints),
                  dotPoses: try c.decodeIfPresent([PoseFeature].self, forKey: .dotPoses) ?? [],
                  learnedPoints: try c.decodeIfPresent([CalibrationPoint].self, forKey: .learnedPoints) ?? [],
                  recentErrors: try c.decodeIfPresent([Double].self, forKey: .recentErrors) ?? [])
    }
}

public enum CalibrationBuilder {
    static let minSamplesPerTarget = 5

    /// `targets`: each on-screen target (local [0,1]) with the samples collected while it was shown.
    public static func build(targets: [(target: CGPoint, samples: [GazeSample])], minConfidence: Double) -> DisplayCalibration? {
        var points: [CalibrationPoint] = []
        var poses: [PoseFeature] = []
        var dots: [PoseFeature] = []
        for (target, samples) in targets {
            let good = samples.filter {
                $0.confidence >= minConfidence && $0.raw.x.isFinite && $0.raw.y.isFinite
                    && $0.pose.isFinite
            }
            guard good.count >= minSamplesPerTarget else { continue }
            points.append(CalibrationPoint(
                input: CGPoint(x: median(good.map { $0.raw.x }), y: median(good.map { $0.raw.y })), target: target))
            poses += good.map(\.pose)
            if let p = PoseFeature.median(of: good.map(\.pose)) { dots.append(p) }
        }
        guard points.count >= 3, let pose = PoseFeature.median(of: poses) else { return nil }
        return DisplayCalibration(pose: pose, calibrationPoints: points, dotPoses: dots)
    }
}

extension CalibrationBuilder {
    /// Screens whose head poses are closer than this can't be told apart by head direction
    /// (the user moved only their eyes): 0.05 ≈ 3°, about twice the pose jitter at rest.
    public static let minScreenSeparation = 0.05

    /// Keys of screens that "looked the same to the camera" (calibration error shown by the app).
    public static func indistinguishable(_ cals: [String: DisplayCalibration]) -> [String] {
        cals.keys.filter { k in
            cals.contains { $0.key != k && $0.value.pose.distance(to: cals[k]!.pose) < minScreenSeparation }
        }.sorted()
    }
}
