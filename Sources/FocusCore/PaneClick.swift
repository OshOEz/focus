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
    /// is inside none of `occluders`. "click in the middle of the pane", never in
    /// other apps.
    ///
    /// (b) alone cannot see everything above the pane: `world.windows` is `WindowProvider`'s
    /// layer-0, non-Focus snapshot (docs/superpowers/plans/2026-09-30-plan-3a-engine-focusmac.md
    /// ~l.2165), so a floating panel (NSPanel `.floating`, PiP, a visio mini-window) never appears
    /// there and would silently pass (b). `occluders` is the explicit, layer-agnostic fix (issue #19,
    /// reconciliation R11): right before posting, the caller (`FocusActuator`) reads the on-screen
    /// windows **above** `window` with no layer filter (`.optionOnScreenAboveWindow`) and passes
    /// their frames minus Focus's own and alpha-0 windows. Windows below `window` cannot take the
    /// click; the default `[]` is for tests only.
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
