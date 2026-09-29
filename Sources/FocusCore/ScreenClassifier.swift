import Foundation

/// Picks the screen the head faces: nearest calibrated pose centroid, with hysteresis.
public struct ScreenClassifier: Sendable {
    public var centroids: [String: PoseFeature]
    public var hysteresis: Double
    public var maxDistance: Double
    public private(set) var current: String?

    public init(centroids: [String: PoseFeature], hysteresis: Double, maxDistance: Double) {
        self.centroids = centroids; self.hysteresis = hysteresis; self.maxDistance = maxDistance
    }

    public mutating func classify(_ pose: PoseFeature) -> String? {
        guard let nearest = centroids.map({ ($0.key, $0.value.distance(to: pose)) }).min(by: { $0.1 < $1.1 }),
              nearest.1 <= maxDistance
        else { current = nil; return nil }
        let (best, bestD) = nearest
        if let cur = current, cur != best, let curC = centroids[cur],
           bestD > curC.distance(to: pose) * (1 - hysteresis) {
            return cur
        }
        current = best
        return best
    }
}
