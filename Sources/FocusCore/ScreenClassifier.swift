import Foundation

/// Picks the screen the head faces.
///
/// Off-screen: farther than `maxDistance` from the yaw × pitch box every screen's dots span, or than
/// `legacyCentroidDistance` from the centroid of a calibration without dots → nil (phone, desk, ceiling).
/// Switching: for the current screen C and a neighbour N, the pose is projected on the C→N
/// axis and expressed as a fraction `s` of the gap between the facing edges of their
/// calibration clouds (0 = C's nearest dot, 1 = N's nearest dot). N takes over once `s`
/// passes `threshold` = 0.5 + (headTurn − 0.3) / 2, i.e. 0.5…0.7 for the 30…70 % setting.
/// Never below the midpoint, so two screens can't both claim a pose (no ping-pong at the bezel,
/// whatever the setting); going back to the screen just left needs `returnBand` more
/// (hysteresis: a small drift back doesn't undo a switch). Details: docs/wiki/Decision-engine.md.
public struct ScreenClassifier: Sendable {
    public static let returnBand = 0.05
    /// Narrowest facing-edge gap the switch fraction is computed over: 2.5 × minScreenSeparation
    /// (0.125 rad ≈ 7°). Measured with bench `bezel/*` over head distances 800-2400 pt: 1.5× still
    /// flips twice on laptop-below, 2× twice at 900 pt, 2.5× never more than once; switch latency
    /// p50 stays 267 ms (laptop-below p95 267 → 333 ms, one frame, from the wider dead band).
    public static let minGap = 2.5 * CalibrationBuilder.minScreenSeparation
    /// The off-screen distance calibrations saved without dots were used with (the rule before edge dots).
    public static let legacyCentroidDistance = 0.35
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
        // From the region the dots span, not the centroid: a close or wide screen spans more than
        // 2 × the margin and its centroid (median of dot poses) leans toward its edge dots, so 40 %
        // of screen A on bench desk laptop-below@1800pt (62 % at 900 pt) read as "away" measured
        // from the centroid. Not from the nearest dot either: points between dots lie up to 0.32 rad
        // from the nearest one at 700 pt, more than a phone 20° past the edge (0.25). From the box,
        // no on-screen point is farther than 0.10 (sweep: docs/wiki/Decision-engine.md, Screen boundary).
        guard let nearest = centroids.min(by: { $0.value.distance(to: pose) < $1.value.distance(to: pose) }),
              centroids.contains(where: { key, c in
                  let dots = clouds[key] ?? []
                  return dots.isEmpty ? c.distance(to: pose) <= Self.legacyCentroidDistance
                                      : Self.distance(pose, toBoxOf: dots) <= maxDistance
              })
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
    /// A screen without dots (old calibration) uses its centroid; narrow or overlapping gaps are
    /// widened to `minGap` around their midpoint so the fraction stays defined and noise-proof.
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
        // The hysteresis inside a gap is a fixed share of its width, so a gap only a few
        // times the pose jitter at rest (σ ≈ 0.01 rad) lets noise alone cross it (edge dots 3 % inside
        // two screens are only ~0.04-0.06 rad apart at 1-2 m). Narrow gaps are therefore widened
        // around their midpoint to `minGap`: the boundary stays at the seam, only the dead band grows.
        // Continuous on purpose: the earlier fallback to centroid geometry below a floor just moved
        // the cliff (bench `bezel/*`: 5 flips per 10 s stare at the floor/2, then 2 flips at head
        // distances 1000-1300 pt side-by-side and 1400-1700 pt laptop-below with the full floor).
        if edgeB - edgeA < Self.minGap {
            let mid = (edgeA + edgeB) / 2
            edgeA = max(mid - Self.minGap / 2, 0); edgeB = min(mid + Self.minGap / 2, length)
            if edgeB - edgeA < 1e-9 { edgeA = 0; edgeB = length }   // midpoint outside the centroid span
        }
        return (project(p) - edgeA) / (edgeB - edgeA)
    }

    static func vector(_ p: PoseFeature) -> [Double] { [p.yaw, p.pitch, p.faceX, p.faceY] }

    /// Distance from `p` to the yaw × pitch box of `dots` (0 inside). Yaw follows x and pitch y, so a
    /// screen's cloud is close to a box. Face position is left out: off-screen is about where the head
    /// points, and the dots' face span is ~0 when the user sat still, so a 14 cm lean (0.2 of the
    /// image) would otherwise read as away on every screen.
    static func distance(_ p: PoseFeature, toBoxOf dots: [PoseFeature]) -> Double {
        func outside(_ v: Double, _ xs: [Double]) -> Double { max(xs.min()! - v, 0, v - xs.max()!) }
        return hypot(outside(p.yaw, dots.map(\.yaw)), outside(p.pitch, dots.map(\.pitch)))
    }
}
