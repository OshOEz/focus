import Foundation

/// Picks the screen the head faces.
///
/// Off-screen: farther than `maxDistance` from every centroid → nil (phone, desk, ceiling).
/// Switching: for the current screen C and a neighbour N, the pose is projected on the C→N
/// axis and expressed as a fraction `s` of the gap between the facing edges of their
/// calibration clouds (0 = C's nearest dot, 1 = N's nearest dot). N takes over once `s`
/// passes `threshold` = 0.5 + (headTurn − 0.3) / 2, i.e. 0.5…0.7 for the 30…70 % setting.
/// Never below the midpoint, so two screens can't both claim a pose (no ping-pong at the bezel,
/// whatever the setting); going back to the screen just left needs `returnBand` more
public struct ScreenClassifier: Sendable {
    public static let returnBand = 0.05
    public var centroids: [String: PoseFeature]
    public var clouds: [String: [PoseFeature]]
    public var headTurn: Double
    public var maxDistance: Double
    public private(set) var current: String?
    public private(set) var previous: String?

    public init(centroids: [String: PoseFeature], clouds: [String: [PoseFeature]] = [:], headTurn: Double = 0.5,
                maxDistance: Double) {
        self.centroids = centroids; self.clouds = clouds; self.headTurn = headTurn; self.maxDistance = maxDistance
    }

    public var threshold: Double { 0.5 + (min(max(headTurn, 0.3), 0.7) - 0.3) / 2 }

    public mutating func classify(_ pose: PoseFeature) -> String? {
        guard let nearest = centroids.min(by: { $0.value.distance(to: pose) < $1.value.distance(to: pose) }),
              nearest.value.distance(to: pose) <= maxDistance
        else { current = nil; return nil }
        guard let cur = current, centroids[cur] != nil else { current = nearest.key; return nearest.key }
        var best: (key: String, d: Double)?
        for (key, c) in centroids where key != cur {
            let need = threshold + (key == previous ? Self.returnBand : 0)
            let d = c.distance(to: pose)
            if gapFraction(pose, from: cur, to: key) > need, d < (best?.d ?? .infinity) { best = (key, d) }
        }
        if let best { previous = cur; current = best.key }
        return current
    }

    /// Position of `p` between the facing edges of `a`'s and `b`'s clouds along the a→b axis.
    /// A screen without dots (old calibration) uses its centroid; overlapping clouds fall back to
    /// centroid-to-centroid so the fraction stays defined.
    func gapFraction(_ p: PoseFeature, from a: String, to b: String) -> Double {
        let ca = Self.vector(centroids[a]!), cb = Self.vector(centroids[b]!)
        let axis = zip(cb, ca).map { $0 - $1 }
        let length = axis.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 1e-9 else { return 0 }
        func project(_ q: PoseFeature) -> Double {
            zip(zip(Self.vector(q), ca).map { $0 - $1 }, axis).reduce(0) { $0 + $1.0 * $1.1 } / length
        }
        var edgeA = (clouds[a] ?? []).map(project).max() ?? 0
        var edgeB = (clouds[b] ?? []).map(project).min() ?? length
        // Issue #17: a facing-edge gap this small is calibration-dot noise (pose jitter at rest,
        // see `CalibrationBuilder.minScreenSeparation`), not a real physical edge — dividing by it
        // would turn that noise into a hair-trigger switch. Below the floor, fall back to
        // centroid-to-centroid geometry, same as a display calibrated without dots.
        if edgeB - edgeA < CalibrationBuilder.minScreenSeparation / 2 { edgeA = 0; edgeB = length }
        return (project(p) - edgeA) / (edgeB - edgeA)
    }

    static func vector(_ p: PoseFeature) -> [Double] { [p.yaw, p.pitch, p.faceX, p.faceY] }
}
