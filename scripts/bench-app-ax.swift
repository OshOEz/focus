// Helper for scripts/bench-app.sh: reads (never requests) Accessibility trust for the *calling*
// process, and — only when trusted — counts the target pid's menu bar extras and windows via AX.
// Kept as a standalone script (not part of the SwiftPM package) because bench-app.sh runs before
// the focus-bench harness (feat/benches, unmerged) exists in this branch.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
    print("{\"trusted\":false}")
    exit(0)
}

guard AXIsProcessTrusted() else {   // status read, never a prompt
    print("{\"trusted\":false}")
    exit(0)
}

let ax = AXUIElementCreateApplication(pid)
var extras: CFTypeRef?
var items: CFTypeRef?
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &extras)
if let bar = extras {
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &items)
}
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
let n = (items as? [AXUIElement])?.count ?? 0
let w = (windows as? [AXUIElement])?.count ?? 0
print("{\"trusted\":true,\"menuExtras\":\(n),\"windows\":\(w)}")
