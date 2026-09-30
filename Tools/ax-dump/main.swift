import AppKit
import ApplicationServices
import FocusCore
import FocusMac

// Spike: print the AX tree of every running pane-capable app, to learn which panes AX exposes.
// Usage: swift run ax-dump [extra.bundle.id ...]

func dump(_ e: AXUIElement, depth: Int) {
    guard depth < 25 else { return }
    let role = e.role ?? "?"
    let sub = e.attribute(kAXSubroleAttribute) as? String ?? ""
    let f = e.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
    print(String(repeating: "  ", count: depth) + "\(role) \(sub) [\(f)] focusable=\(e.isFocusSettable)")
    for child in e.children { dump(child, depth: depth + 1) }
}

guard AXIsProcessTrusted() else {
    print("Accessibility is not granted to this terminal (System Settings > Privacy & Security > Accessibility).")
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
usleep(1_000_000)   // spike: Electron trees fill after ~1 s, not 0.5 s

for app in apps {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    print("=== \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
    for w in el.attribute(kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        dump(w, depth: 1)
        let panes = PaneFinder.panes(in: w, windowFrame: w.frame ?? .zero,
                                      minSize: CGSize(width: 200, height: 150), tree: .ax)
        let rects = panes.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        print("  panes: " + (rects.isEmpty ? "none" : rects.joined(separator: "; ")))
    }
}
