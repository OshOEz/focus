import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the calibration dots go (9 dots per screen at x 10/50/90 %, y 12/50/88 %, plus
/// dots along every edge shared with a neighbour, ~1.6 s per dot, ~20 s per screen). The edge dots
/// pin down the facing edge of each screen's pose cloud, which is where ScreenClassifier puts the
/// boundary.
public enum CalibrationLayout {
    public static let gridX: [CGFloat] = [0.1, 0.5, 0.9]
    public static let gridY: [CGFloat] = [0.12, 0.5, 0.88]
    /// Edge dots sit 3 % inside the shared edge: as close to the boundary as is comfortable to look at.
    public static let edgeNear: CGFloat = 0.03
    public static let edgeFar: CGFloat = 0.97
    /// Display frames are integral points; 2 pt absorbs rounding in odd arrangements.
    static let touchTolerance: CGFloat = 2

    /// Per display key, its dots in display-local [0,1] coordinates (y down, like CG).
    public static func targets(for displays: [DisplayInfo]) -> [String: [CGPoint]] {
        var out: [String: [CGPoint]] = [:]
        for d in displays {
            var dots = gridY.flatMap { y in gridX.map { CGPoint(x: $0, y: y) } }
            for other in displays where other.key != d.key { dots += edgeDots(d.frame, touching: other.frame) }
            out[d.key] = dots
        }
        return out
    }

    /// Three dots on the part of `a`'s edge that touches `b`, at 25/50/75 % of the shared span.
    static func edgeDots(_ a: CGRect, touching b: CGRect) -> [CGPoint] {
        let t = touchTolerance
        func along(_ lo: CGFloat, _ hi: CGFloat, _ origin: CGFloat, _ size: CGFloat) -> [CGFloat] {
            guard hi - lo > t else { return [] }   // corners touching diagonally share no edge
            return [0.25, 0.5, 0.75].map { (lo + (hi - lo) * $0 - origin) / size }
        }
        let vertical = along(max(a.minY, b.minY), min(a.maxY, b.maxY), a.minY, a.height)
        let horizontal = along(max(a.minX, b.minX), min(a.maxX, b.maxX), a.minX, a.width)
        if abs(a.maxX - b.minX) <= t { return vertical.map { CGPoint(x: edgeFar, y: $0) } }    // b on the right
        if abs(a.minX - b.maxX) <= t { return vertical.map { CGPoint(x: edgeNear, y: $0) } }   // b on the left
        if abs(a.maxY - b.minY) <= t { return horizontal.map { CGPoint(x: $0, y: edgeFar) } }  // b below
        if abs(a.minY - b.maxY) <= t { return horizontal.map { CGPoint(x: $0, y: edgeNear) } } // b above
        return []
    }
}
