import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum PaneClick {
    /// Where a synthetic click may focus `pane`, or nil when a click is unsafe.
    ///
    /// Always the pane centre, and only when (a) the centre is farther than `paneBoundaryMargin`
    /// from every other pane — a click near a divider can grab it or land in the neighbour —
    /// (b) `window` is the topmost window at that point among `world.windows`, and (c) the centre
    /// is inside none of `occluders`. Clicking the middle of the pane, never another app,
    /// is the only click that can't do something the user didn't ask for.
    ///
    /// (b) alone misses floating panels and PiP windows, invisible to `world.windows`'s layer-0
    /// snapshot; `occluders` (docs/wiki/Focusing-windows-and-panes.md)
    /// is the layer-agnostic fix: the caller reads every on-screen window above `window` right before
    /// posting. Windows below `window` can't take the click; the default `[]` is for tests only.
    public static func point(for pane: CGRect, window: UInt32, world: World,
                             settings: FocusSettings = FocusSettings(), occluders: [CGRect] = []) -> CGPoint? {
        let c = CGPoint(x: pane.midX, y: pane.midY)
        guard let i = world.panes.firstIndex(of: pane),
              let display = world.displays.first(where: { $0.frame.contains(c) }),
              TargetResolver.pane(at: c, panes: world.panes, display: display.frame, settings: settings) == i,
              world.windows.first(where: { $0.frame.contains(c) })?.id == window,
              !occluders.contains(where: { $0.contains(c) })
        else { return nil }
        return c
    }
}
