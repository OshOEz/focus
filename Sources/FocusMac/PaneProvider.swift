import ApplicationServices
import QuartzCore
import FocusCore

/// Split panes of a window, found with `PaneFinder` over the live AX tree.
///
/// Walking a tree costs one AX round trip per node, so results are cached per window: 2 s while
/// panes exist (a new split or a dragged divider shows up within 2 s), 1 s when the tree was empty,
/// because Electron apps build their tree only after `AXManualAccessibility` is set and it arrives
/// about a second later (docs/spikes/ax-panes.md). A moved/resized window invalidates at once.
@MainActor public final class PaneProvider {
    public var allows: (String?) -> Bool = { $0.map(PaneApps.isAllowed) ?? false }
    private let windows: WindowProvider
    private var cache: [UInt32: Entry] = [:]
    private var manualAX: Set<pid_t> = []

    private struct Entry {
        var windowFrame: CGRect
        var panes: [(node: AXUIElement, frame: CGRect)]
        var time: Double
    }

    // AX messaging timeout is process-global and already set to 0.25 s by `WindowProvider.init`
    // (whichever provider is constructed first wins); setting it again here would be redundant
    // and risks drifting out of sync with that value.
    public init(windows: WindowProvider) {
        self.windows = windows
    }

    public func panes(of windowID: UInt32) -> [CGRect] { entry(windowID)?.panes.map(\.frame) ?? [] }

    public func element(of windowID: UInt32, pane: CGRect) -> AXUIElement? {
        entry(windowID)?.panes.first { $0.frame == pane }?.node
    }

    /// The pane holding the app's focused element: walk up from `AXFocusedUIElement` until a pane
    /// element is met. Frames are not enough — the focused element can be a tiny helper inside
    /// the pane (xterm's hidden textarea) or a document taller than the pane.
    public func focusedPaneIndex(of windowID: UInt32, panes: [CGRect]) -> Int? {
        guard let e = entry(windowID), let win = windows.element(for: windowID),
              var node = AXUIElementCreateApplication(win.pid).element(kAXFocusedUIElementAttribute)
        else { return nil }
        for _ in 0..<40 {
            if let hit = e.panes.first(where: { CFEqual($0.node, node) }) { return panes.firstIndex(of: hit.frame) }
            guard let up = node.parent, !CFEqual(up, win) else { return nil }
            node = up
        }
        return nil
    }

    public func invalidate() { cache.removeAll() }

    private func entry(_ id: UInt32) -> Entry? {
        guard allows(windows.bundleID(for: id)), let win = windows.element(for: id), let frame = win.frame
        else { return nil }
        let now = CACurrentMediaTime()
        if let e = cache[id], e.windowFrame == frame, now - e.time < (e.panes.isEmpty ? 1 : 2) { return e }
        let pid = win.pid
        if manualAX.insert(pid).inserted {
            // Chromium/Electron only expose their tree once asked; harmless error for native apps.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let e = Entry(windowFrame: frame,
                      panes: PaneFinder.panes(in: win, windowFrame: frame,
                                              minSize: CGSize(width: 200, height: 150), tree: .ax),
                      time: now)
        cache = cache.filter { now - $0.value.time < 30 }
        cache[id] = e
        return e
    }
}
