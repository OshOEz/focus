import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Head pose + face position in the camera image. Angles in radians, face in [0,1].
public struct PoseFeature: Codable, Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var faceX: Double
    public var faceY: Double

    public init(yaw: Double, pitch: Double, faceX: Double, faceY: Double) {
        self.yaw = yaw; self.pitch = pitch; self.faceX = faceX; self.faceY = faceY
    }

    // ponytail: unweighted Euclidean over radians and [0,1]; add per-axis weights if pitch noise hurts stacked screens.
    public func distance(to o: PoseFeature) -> Double {
        let d = [yaw - o.yaw, pitch - o.pitch, faceX - o.faceX, faceY - o.faceY]
        return d.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}

/// One camera frame's output from GazeKit.
public struct GazeSample: Sendable {
    public var time: Double        // seconds, host clock (CACurrentMediaTime base)
    public var raw: CGPoint        // BlazeGaze point before calibration
    public var pose: PoseFeature
    public var confidence: Double  // 0…1

    public init(time: Double, raw: CGPoint, pose: PoseFeature, confidence: Double) {
        self.time = time; self.raw = raw; self.pose = pose; self.confidence = confidence
    }
}

extension GazeSample {
    /// What GazeKit yields for a frame without a usable face, so consumers keep getting a
    /// heartbeat ("Looking for your face") and any pending dwell is reset.
    public static func noFace(at time: Double) -> GazeSample {
        GazeSample(time: time, raw: CGPoint(x: Double.nan, y: .nan),
                   pose: PoseFeature(yaw: .nan, pitch: .nan, faceX: .nan, faceY: .nan), confidence: 0)
    }

    public var hasFace: Bool { confidence > 0 && raw.x.isFinite && raw.y.isFinite && pose.isFinite }
}

extension PoseFeature {
    public var isFinite: Bool { yaw.isFinite && pitch.isFinite && faceX.isFinite && faceY.isFinite }

    /// Component-wise median of the finite poses; nil when there are none.
    public static func median(of poses: [PoseFeature]) -> PoseFeature? {
        let ok = poses.filter(\.isFinite)
        guard !ok.isEmpty else { return nil }
        return PoseFeature(yaw: FocusCore.median(ok.map(\.yaw)), pitch: FocusCore.median(ok.map(\.pitch)),
                           faceX: FocusCore.median(ok.map(\.faceX)), faceY: FocusCore.median(ok.map(\.faceY)))
    }
}
