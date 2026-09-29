import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One (observed gaze → true point) pair, both in display-local [0,1] coordinates.
public struct CalibrationPoint: Codable, Sendable, Equatable {
    public var input: CGPoint
    public var target: CGPoint
    public init(input: CGPoint, target: CGPoint) { self.input = input; self.target = target }
}

/// Gaussian RBF fitted on the residual (target − input), so far from the data it returns
/// the input unchanged. Same kernel and ridge as MacGaze's RBFGazeCorrector (MIT).
public struct RBFMap: Sendable {
    let centers: [CGPoint]
    let weights: [Double]   // n×2 row-major
    let sigma: Double

    public init?(points: [CalibrationPoint], ridge: Double = 0.01) {
        let n = points.count
        guard n >= 3 else { return nil }
        let centers = points.map(\.input)
        let sigma = max(Self.meanDistance(centers), 1e-6)
        var k = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n { k[i * n + j] = Self.kernel(centers[i], centers[j], sigma) }
            k[i * n + i] += ridge
        }
        let y: [Double] = points.flatMap { [$0.target.x - $0.input.x, $0.target.y - $0.input.y] }
        guard let w = solveLinear(k, y, n: n, m: 2), w.allSatisfy(\.isFinite) else { return nil }
        self.centers = centers
        self.weights = w
        self.sigma = sigma
    }

    public func map(_ p: CGPoint) -> CGPoint {
        var dx = 0.0, dy = 0.0
        for (i, c) in centers.enumerated() {
            let phi = Self.kernel(p, c, sigma)
            dx += weights[i * 2] * phi
            dy += weights[i * 2 + 1] * phi
        }
        return CGPoint(x: p.x + dx, y: p.y + dy)
    }

    static func kernel(_ a: CGPoint, _ b: CGPoint, _ sigma: Double) -> Double {
        let d2 = (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
        return exp(-d2 / (2 * sigma * sigma))
    }

    static func meanDistance(_ ps: [CGPoint]) -> Double {
        var sum = 0.0, count = 0
        for i in 0..<ps.count {
            for j in (i + 1)..<ps.count {
                sum += hypot(ps[i].x - ps[j].x, ps[i].y - ps[j].y)
                count += 1
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }
}
