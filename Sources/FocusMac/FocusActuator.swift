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
    /// True while a Focus window that can catch the click is on screen (calibration; later settings
    /// and onboarding): a synthetic click would land on it instead of the target pane. Set by
    /// `AppController`. The gaze overlay is exempt because it sets `ignoresMouseEvents` and passes
    /// clicks through, so it never needs this.
    public var suppressSyntheticClick = false
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
        guard syntheticClickFallback, !suppressSyntheticClick, panes.allows(windows.bundleID(for: window)),
              CGPreflightPostEventAccess()
        else { return false }
        var settings = FocusSettings()
        settings.paneBoundaryMargin = paneBoundaryMargin
        // Occluders are read right before posting: a panel that appeared since the World snapshot
        // must still block the click (audit #19). Nil = the target closed or left the screen:
        // fail closed rather than click whatever is there now.
        guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], window)
                as? [[String: Any]],
              let p = PaneClick.point(for: frame, window: window, world: world, settings: settings,
                                      occluders: Self.occluders(in: above, excludingPID: getpid(), window: window,
                                                                dockStrips: Self.dockStrips(), displayFrames: Self.displayFrames()))
        else { return false }
        let saved = CGEvent(source: nil)?.location
        guard Self.postMarkedClick(at: p) else { return false }
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
    /// The Dock is special: alongside its real UI (bar, stack popup, running-apps menu — ordinary
    /// occluders), it owns an always-on, click-through window spanning the whole display at layer 20
    /// with alpha 1 (bench 4, 2026-09-30), which would block every click. Only that one window is
    /// recognised — by its bounds matching a display's frame exactly AND its layer being exactly 20,
    /// the value observed for the permanent window on this machine — and dropped; `dockStrips` (its
    /// real bar, see `dockStrip`) count in its place when it is above. Launchpad and Mission Control
    /// also span a whole display and are owned by the Dock, but sit at a different layer (audit #27):
    /// the layer check keeps them as occluders, so a pane click never lands on them.
    public nonisolated static func occluders(in raw: [[String: Any]], excludingPID pid: pid_t, window: UInt32,
                                             dockStrips: [CGRect] = [], displayFrames: [CGRect] = []) -> [CGRect] {
        let isInvisibleDockWindow = { (w: [String: Any]) -> Bool in
            guard w[kCGWindowOwnerName as String] as? String == "Dock",
                  w[kCGWindowLayer as String] as? Int == 20,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b)
            else { return false }
            return displayFrames.contains(bounds)
        }
        return raw.compactMap { w in
            guard !isInvisibleDockWindow(w), (w[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  (w[kCGWindowNumber as String] as? UInt32) != window,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: b)
        } + (raw.contains(where: isInvisibleDockWindow) ? dockStrips : [])
    }

    /// The Dock's bar on one screen, in global CG coordinates: the side of `frame` that
    /// `visibleFrame` gives up (Cocoa, bottom-left origin; `primaryHeight` flips y). The top gap is
    /// the menu bar, never the Dock; an auto-hidden Dock gives up nothing → nil. Full width/height
    /// of that side, not the bar's exact length (unknown without private API): errs on "blocked".
    public nonisolated static func dockStrip(frame f: CGRect, visibleFrame v: CGRect, primaryHeight: CGFloat) -> CGRect? {
        let cocoa: CGRect
        if v.minY > f.minY { cocoa = CGRect(x: f.minX, y: f.minY, width: f.width, height: v.minY - f.minY) }
        else if v.minX > f.minX { cocoa = CGRect(x: f.minX, y: f.minY, width: v.minX - f.minX, height: f.height) }
        else if v.maxX < f.maxX { cocoa = CGRect(x: v.maxX, y: f.minY, width: f.maxX - v.maxX, height: f.height) }
        else { return nil }
        return CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    /// `dockStrip` for every screen (only the one showing the Dock has one).
    public static func dockStrips() -> [CGRect] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { dockStrip(frame: $0.frame, visibleFrame: $0.visibleFrame, primaryHeight: h) }
    }

    /// Every screen's full frame in the same global CG coordinates `dockStrip` converts into (Cocoa
    /// bottom-left → CG top-left, flipped against the primary screen's height): what `occluders`
    /// matches the Dock's invisible full-display window against.
    public static func displayFrames() -> [CGRect] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: h - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    /// The pane-click fallback's posting (R10, bench 4), shared verbatim with focus-bench so its
    /// probe matches exactly what ships: a `.privateState` source keeps our synthetic flags out of
    /// the user's modifier state, the marker lets InputMonitor's NSEvent click monitors drop it, and
    /// the session tap (not HID) keeps the click off the .hidSystemState idle counters InputMonitor
    /// reads (2026-09-30: an HID-tap post reset the leftMouseDown idle 97.9 s → 0.16 s).
    public static func postMarkedClick(at p: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { return false }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticMarker)
            e.post(tap: .cgSessionEventTap)
        }
        return true
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
