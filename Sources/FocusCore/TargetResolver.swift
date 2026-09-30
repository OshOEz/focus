import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum TargetResolver {
    /// Topmost big-enough window under `p`; the current window wins while `p` stays within the stick margin.
    public static func window(at p: CGPoint, windows: [WindowInfo], current: UInt32?, display: CGRect,
                              settings s: FocusSettings) -> UInt32? {
        let margin = s.windowStickMargin * display.width
        if let current, let w = windows.first(where: { $0.id == current }),
           w.frame.insetBy(dx: -margin, dy: -margin).contains(p) {
            return current
        }
        return windows.first {
            $0.frame.width >= s.minWindowSize.width && $0.frame.height >= s.minWindowSize.height && $0.frame.contains(p)
        }?.id
    }

    /// Index of the pane under `p`, or nil when there is a single pane or `p` is near a boundary.
    public static func pane(at p: CGPoint, panes: [CGRect], display: CGRect, settings s: FocusSettings) -> Int? {
        guard panes.count > 1, let i = panes.firstIndex(where: { $0.contains(p) }) else { return nil }
        let m = s.paneBoundaryMargin * display.width
        for (j, r) in panes.enumerated() where j != i && r.insetBy(dx: -m, dy: -m).contains(p) { return nil }
        return i
    }

    /// Window to focus when switching to a screen without a gazed window: the last one used there
    /// if it is still on it, else the topmost big-enough window centred on it.
    public static func windowToRestore(on display: CGRect, windows: [WindowInfo], last: UInt32?,
                                       minSize: CGSize = CGSize(width: 200, height: 150)) -> UInt32? {
        let here = windows.filter { display.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        if let last, here.contains(where: { $0.id == last }) { return last }
        return here.first { $0.frame.width >= minSize.width && $0.frame.height >= minSize.height }?.id
    }
}
