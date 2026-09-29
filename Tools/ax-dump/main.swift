import AppKit
import ApplicationServices
import FocusCore

// Spike: print the AX tree of every running pane-capable app, to learn which panes AX exposes.
// Usage: swift run ax-dump [extra.bundle.id ...]

func value(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func focusSettable(_ e: AXUIElement) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success
        && settable.boolValue
}

func dump(_ e: AXUIElement, depth: Int) {
    guard depth < 25 else { return }
    let role = value(e, kAXRoleAttribute) as? String ?? "?"
    let sub = value(e, kAXSubroleAttribute) as? String ?? ""
    let f = frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
    print(String(repeating: "  ", count: depth) + "\(role) \(sub) [\(f)] focusable=\(focusSettable(e))")
    for child in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        dump(child, depth: depth + 1)
    }
}

let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    print("Grant Accessibility to your terminal (System Settings > Privacy & Security > Accessibility), then rerun.")
    exit(1)
}

let extra = Set(CommandLine.arguments.dropFirst())
let apps = NSWorkspace.shared.runningApplications.filter {
    guard let id = $0.bundleIdentifier else { return false }
    return PaneApps.isAllowed(id) || extra.contains(id)
}
// Electron/Chromium apps (VS Code, Cursor…) only build their AX tree once asked.
for app in apps {
    AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
}
usleep(500_000)

for app in apps {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    print("=== \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
    for w in value(el, kAXWindowsAttribute) as? [AXUIElement] ?? [] { dump(w, depth: 1) }
}
