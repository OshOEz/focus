import AppKit
import ApplicationServices
import FocusCore

/// Performs the engine's actions through Accessibility: never a click for windows.
@MainActor public final class FocusActuator {
    /// Settings "move pointer": bring the pointer onto the focused window when focus changes screen,
    /// so Spaces, Mission Control and new windows follow.
    public var moveCursor = true
    /// Plan 4's setting; read by `paneFocuser`.
    public var syntheticClickFallback = true
    /// Plan 4 installs pane focusing here (AX focus, then the click fallback). Until then pane
    /// actions report no effect and the engine's latch stops them repeating.
    public var paneFocuser: ((_ window: UInt32, _ pane: CGRect) -> Bool)?
    private let windows: WindowProvider
    private var lastWindow: [String: UInt32] = [:]

    public init(windows: WindowProvider) { self.windows = windows }

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
            return paneFocuser?(window, frame) ?? false
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
