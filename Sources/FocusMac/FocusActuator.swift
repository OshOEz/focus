import AppKit
import ApplicationServices
import FocusCore
import QuartzCore

/// Performs the engine's actions through Accessibility: never a click for windows.
@MainActor public final class FocusActuator {
    /// Settings "move pointer": bring the pointer onto the focused window when focus changes screen,
    /// so Spaces, Mission Control and new windows follow.
    public var moveCursor = true
    /// Settings "click to focus panes" (`FocusSettings.syntheticClickFallback`); read by `focusPane`.
    public var syntheticClickFallback = true
    /// Mirror of `FocusSettings.paneBoundaryMargin`, so `PaneClick` judges the click point with the
    /// same margin the engine used to pick the pane.
    public var paneBoundaryMargin = FocusSettings().paneBoundaryMargin
    /// Pane focusing; `init` installs `focusPane` (AX focus, then the click fallback). Nil = pane
    /// actions report no effect and the engine's latch stops them repeating.
    public var paneFocuser: ((_ window: UInt32, _ pane: CGRect, _ world: World) -> Bool)?
    private let windows: WindowProvider
    private let panes: PaneProvider
    private var lastWindow: [String: UInt32] = [:]

    public init(windows: WindowProvider, panes: PaneProvider) {
        self.windows = windows
        self.panes = panes
        paneFocuser = { [unowned self] in self.focusPane(window: $0, frame: $1, world: $2) }
    }

    /// Per-display history: the window to bring back when the user turns to that screen.
    public func noteFocusChange(windowID: UInt32, display: String) { lastWindow[display] = windowID }

    public func perform(_ action: FocusAction, world: World) -> Bool {
        // Whatever the user focused by hand is the one to restore when they come back to that screen.
        if let id = world.focusedWindowID, let key = displayKey(of: id, world) { noteFocusChange(windowID: id, display: key) }
        switch action {
        case .display(let key):
            guard let d = world.displays.first(where: { $0.key == key }) else { return false }
            guard let id = TargetResolver.windowToRestore(on: d.frame, windows: world.windows, last: lastWindow[key]) else {
                if moveCursor { warp(to: CGPoint(x: d.frame.midX, y: d.frame.midY)) }   // empty screen: the pointer still follows
                return false
            }
            return focus(id, world: world, warp: moveCursor)
        case .window(let id):
            let crossing = displayKey(of: id, world) != world.focusedWindowID.flatMap { displayKey(of: $0, world) }
            return focus(id, world: world, warp: moveCursor && crossing)
        case .pane(let window, let frame):
            return paneFocuser?(window, frame, world) ?? false
        }
    }

    private func focus(_ id: UInt32, world: World, warp: Bool) -> Bool {
        guard let window = windows.element(for: id), let pid = windows.pid(for: id) else { return false }
        let app = AXUIElementCreateApplication(pid)
        // Frontmost via AX first: since macOS 14, NSRunningApplication.activate from a background
        // agent is "cooperative" and may be ignored, while the AX attribute is honoured for trusted
        // clients. Then main + raise pick the window inside the app (AeroSpace/Rectangle order).
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard raised else { return false }
        if let key = displayKey(of: id, world) { noteFocusChange(windowID: id, display: key) }
        if warp, let f = world.windows.first(where: { $0.id == id })?.frame { self.warp(to: CGPoint(x: f.midX, y: f.midY)) }
        return true
    }

    /// Pane focus, Accessibility first; a click at the pane centre only when the app
    /// ignores AX focus, only in allow-listed apps, only when `PaneClick` finds a safe point.
    /// Success is read back from the app (the focused element's ancestors), never assumed: some
    /// terminals accept `AXFocused` without moving keyboard focus.
    private func focusPane(window: UInt32, frame: CGRect, world: World) -> Bool {
        guard let target = world.panes.firstIndex(of: frame), let pane = panes.element(of: window, pane: frame)
        else { return false }
        let focused = { self.panes.focusedPaneIndex(of: window, panes: world.panes) == target }
        if AXUIElementSetAttributeValue(pane, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
           waitUntil(0.1, focused) { return true }
        guard syntheticClickFallback, panes.allows(windows.bundleID(for: window)), CGPreflightPostEventAccess()
        else { return false }
        var settings = FocusSettings()
        settings.paneBoundaryMargin = paneBoundaryMargin
        // Occluders are read right before posting: a panel that appeared since the World snapshot
        // must still block the click (audit #19). Nil = the target closed or left the screen:
        // fail closed rather than click whatever is there now.
        guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], window)
                as? [[String: Any]],
              let p = PaneClick.point(for: frame, window: window, world: world, settings: settings,
                                      occluders: Self.occluders(in: above, excludingPID: getpid(), window: window))
        else { return false }
        let saved = CGEvent(source: nil)?.location
        // .privateState: the click never enters the .hidSystemState idle counters InputMonitor
        // reads, and the marker lets its NSEvent click monitors drop it (R10).
        let source = CGEventSource(stateID: .privateState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { return false }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
        usleep(20_000)   // one tick for the window server to take down/up before the pointer restore
        let ok = waitUntil(0.15, focused)
        // Restore only after the wait: the posted events move the pointer when the window server
        // processes them, so warping earlier could be undone by the click itself.
        if !moveCursor, let saved { warp(to: saved) }
        return ok
    }

    /// Frames that may cover the pane (R11): every layer (floating panels, PiP, overlays), minus
    /// Focus's own windows, the target and alpha-0 windows (invisible full-screen overlays of other
    /// tools would otherwise block every click). Callers pass windows above the target only —
    /// anything below it cannot receive the click, and counting it would refuse most clicks.
    nonisolated static func occluders(in raw: [[String: Any]], excludingPID pid: pid_t, window: UInt32) -> [CGRect] {
        raw.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) != pid, (w[kCGWindowNumber as String] as? UInt32) != window,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: b)
        }
    }

    /// Polls `condition` every 20 ms for up to `seconds`.
    /// ponytail: blocks the MainActor. Nominal ≤ 270 ms per pane switch (rare, user-paced), but each
    /// poll walks AX (focused element + up to 40 parents, a tree re-walk on cache expiry), every call
    /// bounded only by the 0.25 s AX timeout — a hung app can stretch one poll to seconds. Move to an
    /// async check if gaze frames are dropped around pane switches.
    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + seconds
        repeat {
            if condition() { return true }
            usleep(20_000)
        } while CACurrentMediaTime() < end
        return condition()
    }

    /// Moves the pointer without posting a mouse event. Re-associating right away avoids the
    /// ~0.25 s freeze macOS applies to the pointer after a warp.
    private func warp(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func displayKey(of id: UInt32, _ world: World) -> String? {
        guard let f = world.windows.first(where: { $0.id == id })?.frame else { return nil }
        return world.displays.first { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) }?.key
    }
}
