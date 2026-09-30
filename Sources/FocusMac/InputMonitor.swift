import AppKit
import FocusCore
import QuartzCore

/// Keyboard and pointer activity without the Input Monitoring permission (Focus asks
/// only for Camera and Accessibility). Times come from the hardware (HID) idle counters only, so Focus's own
/// synthetic events (the pane click fallback, posted at the session tap: the HID tap
/// would reset these counters whatever the source state, bench 4) never count as user activity;
/// clicks come from NSEvent monitors, only for their position (learning), which is passed on and
/// not kept.
/// Trade-off: software-injected input from other tools (Screen Sharing, remote control) no longer
/// resets the idle counters either. `CGWarpMouseCursorPosition` (our own cursor moves) generates
/// no events either way (CGRemoteOperation.h), so it's unaffected by this choice.
@MainActor public final class InputMonitor {
    /// Marker Focus stamps on its own synthetic clicks (the pane click fallback,
    /// `CGEventSourceSetUserData` on post) so this monitor never learns from itself.
    static let syntheticMarker: Int64 = 0x464F4355

    public var onClick: ((CGPoint, Double) -> Void)?
    /// Written only on the main actor (`start`/`stop`); `deinit` is nonisolated and needs to reach it.
    private nonisolated(unsafe) var monitors: [Any] = []
    private var lastClick = -Double.infinity
    private static let mouseEvents: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                     .leftMouseDragged, .rightMouseDragged, .scrollWheel]

    public init() {}

    /// Polled once per decision; on the CACurrentMediaTime base like GazeSample.time.
    public var activity: InputActivity {
        let now = CACurrentMediaTime()
        func since(_ t: CGEventType) -> Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: t) }
        let mouse = Self.mouseEvents.map(since).min() ?? .infinity
        // .keyDown only: a bare modifier (.flagsChanged, e.g. holding ⌘) is deliberately not typing.
        return InputActivity(lastKey: now - since(.keyDown), lastMouse: max(now - mouse, lastClick))
    }

    /// Global monitor = clicks in other apps (Accessibility); local = clicks in our own windows.
    public func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.click(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.click(e) }
            return e
        }) { monitors.append(l) }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func click(_ e: NSEvent) {
        // Ignore clicks Focus posted itself (pane click fallback), or the
        // engine would "learn" from its own action and reset the mouse-quiet window it just used.
        guard let cgEvent = e.cgEvent, cgEvent.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return }
        let t = CACurrentMediaTime()   // stamped here, same clock as GazeSample.time
        lastClick = t
        // cgEvent.location is already global CG (top-left origin), the World's space.
        onClick?(cgEvent.location, t)
    }
}
