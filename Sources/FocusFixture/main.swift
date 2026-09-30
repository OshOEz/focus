import AppKit
import FocusMac

// Test app for focus-bench: two plain windows side by side on the main screen; the second holds
// a vertical split of two text views (plan 4 uses it for panes). Prints its window ids and frames,
// plus how many of its own windows CGWindowList shows (`selfOnScreen`) and how many a
// WindowProvider in this process lists (`selfListed`, must be 0: Focus never focuses itself).

/// A pane's text view. Prints the plan 4 probe protocol (`pane-focused <i>` / `pane-clicked <i>`,
/// flushed at once so the bench's line reader sees them without buffering delay).
final class PaneTextView: NSTextView {
    var index = 0
    static var refuseAX = CommandLine.arguments.contains("--refuse-ax-focus")
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { print("pane-focused \(index)"); fflush(stdout) }
        return ok
    }
    override func mouseDown(with event: NSEvent) {
        print("pane-clicked \(index)"); fflush(stdout)
        super.mouseDown(with: event)
    }
    // Simulates a terminal that refuses focus from other apps, to exercise the click fallback.
    override func setAccessibilityFocused(_ focused: Bool) {
        if !Self.refuseAX { super.setAccessibilityFocused(focused) }
    }
}

// Process launch time, not a `static let` on the view: a type's `static let` initializes lazily on
// first access, which here would be the first AX query — pushing "1.5 s after launch" out to
// "1.5 s after the bench first asked", silently widening the late-tree window by however long the
// bench took to get around to asking. A top-level `let` in this file's linear execution runs eagerly.
let fixtureLaunchTime = Date()

/// Simulates Electron: the AX tree is empty right after the first read, filled ~1 s later
/// (`--late-ax`), exercising `PaneProvider`'s empty-tree retry.
final class FixtureSplitView: NSSplitView {
    override func accessibilityChildren() -> [Any]? {
        CommandLine.arguments.contains("--late-ax") && Date().timeIntervalSince(fixtureLaunchTime) < 1.5
            ? [] : super.accessibilityChildren()
    }
}

let args = CommandLine.arguments
let quitAfter = args.firstIndex(of: "--quit-after").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 120

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[0]                 // primary: its top-left is the CG origin
@MainActor func window(_ n: Int, cgX: CGFloat, size: CGSize) -> NSWindow {
    // Cocoa frames are bottom-left based; CG y = primary height − Cocoa maxY.
    let origin = CGPoint(x: cgX, y: screen.frame.height - 120 - size.height)
    let w = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.titled, .resizable],
                     backing: .buffered, defer: false)
    w.title = "Focus fixture \(n)"
    w.isReleasedWhenClosed = false
    return w
}
/// A pane text view inside a scroll view, built the way `NSTextView.scrollableTextView()` wires one
/// up — but as a `PaneTextView`, which that factory can't produce.
@MainActor func paneScrollView(index: Int) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let textView = PaneTextView(frame: scroll.bounds)
    textView.index = index
    textView.autoresizingMask = [.width]
    textView.isVerticallyResizable = true
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    scroll.documentView = textView
    return scroll
}
let w1 = window(1, cgX: 100, size: CGSize(width: 640, height: 420))
// Window 2 hosts the split: ≥ 800 pt wide so each pane clears the ≥ 300×300 pt bar (task 8 brief).
let w2Size = CGSize(width: 820, height: 420)
let w2x = min(800, screen.frame.width - w2Size.width)   // clamp: must still fit the primary screen
let w2 = window(2, cgX: w2x, size: w2Size)
let split = FixtureSplitView(frame: w2.contentView!.bounds)
split.isVertical = true
split.autoresizingMask = [.width, .height]
for i in 0..<2 { split.addArrangedSubview(paneScrollView(index: i)) }
w2.contentView!.addSubview(split)
// Becoming key would otherwise auto-focus a pane text view (AppKit's default key view loop), printing
// a spurious `pane-focused` before anything asked for one; only an explicit AX/click probe should.
w2.initialFirstResponder = w2.contentView
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
        // try!: every value below is a literal Int/String/Array, all JSON-safe; encoding cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: ["pid": getpid(), "windows": list,
                                                                "selfOnScreen": onScreen.count, "selfListed": listed.count])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { exit(0) }
app.run()
