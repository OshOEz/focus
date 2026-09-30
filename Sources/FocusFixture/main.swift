import AppKit
import FocusMac

// Test app for focus-bench: two plain windows side by side on the main screen; the second holds
// a vertical split of two text views (plan 4 uses it for panes). Prints its window ids and frames,
// plus how many of its own windows CGWindowList shows (`selfOnScreen`) and how many a
// WindowProvider in this process lists (`selfListed`, must be 0: Focus never focuses itself).

let args = CommandLine.arguments
let quitAfter = args.firstIndex(of: "--quit-after").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 120

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[0]                 // primary: its top-left is the CG origin
@MainActor func window(_ n: Int, cgX: CGFloat) -> NSWindow {
    let size = CGSize(width: 640, height: 420)
    // Cocoa frames are bottom-left based; CG y = primary height − Cocoa maxY.
    let origin = CGPoint(x: cgX, y: screen.frame.height - 120 - size.height)
    let w = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.titled, .resizable],
                     backing: .buffered, defer: false)
    w.title = "Focus fixture \(n)"
    w.isReleasedWhenClosed = false
    return w
}
let w1 = window(1, cgX: 100)
let w2x = min(800, screen.frame.width - 640)   // clamp: window 2 (640 wide) must still fit the primary screen
let w2 = window(2, cgX: w2x)
let split = NSSplitView(frame: w2.contentView!.bounds)
split.isVertical = true
split.autoresizingMask = [.width, .height]
for _ in 0..<2 {
    let scroll = NSTextView.scrollableTextView()
    split.addArrangedSubview(scroll)
}
w2.contentView!.addSubview(split)
for w in [w1, w2] { w.makeKeyAndOrderFront(nil) }
app.activate()

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    MainActor.assumeIsolated {
        let h = screen.frame.height
        let list = [w1, w2].map { w -> [String: Any] in
            ["id": w.windowNumber, "frame": [w.frame.minX, h - w.frame.maxY, w.frame.width, w.frame.height]]
        }
        let ids = Set([w1, w2].map { UInt32($0.windowNumber) })
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = raw.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let listed = WindowProvider().windows().filter { ids.contains($0.id) }
        let data = try! JSONSerialization.data(withJSONObject: ["pid": getpid(), "windows": list,
                                                                "selfOnScreen": onScreen.count, "selfListed": listed.count])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { exit(0) }
app.run()
