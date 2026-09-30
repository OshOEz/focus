import AppKit
import ApplicationServices
import FocusCore

/// Private but stable since 10.x and used by AeroSpace, yabai, AltTab: the only way to map an
/// AX window to its CGWindowID, which is what CGWindowList and the engine speak.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Normal windows of the current Space, front to back, from CGWindowList (no permission needed
/// for ids and bounds; titles would need Screen Recording and are never read). AX lookups need
/// Accessibility and simply fail without it.
@MainActor public final class WindowProvider {
    /// A hung app blocks AX calls for the 6 s default; 0.25 s keeps one stuck app from freezing focus.
    /// Set on the system-wide element, it becomes the global timeout for every AX element we create.
    static let axTimeout: Float = 0.25
    private var owners: [UInt32: pid_t] = [:]
    private var cache: [UInt32: AXUIElement] = [:]

    public init() { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.axTimeout) }

    public func windows() -> [WindowInfo] {
        let me = getpid()
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var out: [WindowInfo] = []
        var owners: [UInt32: pid_t] = [:]
        for w in raw {
            guard (w[kCGWindowLayer as String] as? Int) == 0,                  // normal windows, not menus/overlays
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b), frame.width > 0, frame.height > 0
            else { continue }
            owners[id] = pid
            out.append(WindowInfo(id: id, frame: frame))
        }
        self.owners = owners
        cache = cache.filter { owners[$0.key] != nil }
        return out
    }

    /// Asks the system-wide AX element (always current) rather than NSWorkspace.frontmostApplication,
    /// which only updates while a run loop is pumping notifications.
    public func focusedWindowID() -> UInt32? {
        let system = AXUIElementCreateSystemWide()
        guard let app = copy(system, kAXFocusedApplicationAttribute),
              let window = copy(app as! AXUIElement, kAXFocusedWindowAttribute) else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window as! AXUIElement, &id) == .success ? id : nil
    }

    public func element(for id: UInt32) -> AXUIElement? {
        if let e = cache[id] { return e }
        guard let pid = pid(for: id) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        for w in copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid == id { cache[id] = w; return w }
        }
        return nil
    }

    public func pid(for id: UInt32) -> pid_t? {
        if owners[id] == nil { _ = windows() }
        return owners[id]
    }

    public func bundleID(for id: UInt32) -> String? {
        pid(for: id).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    private func copy(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }
}
