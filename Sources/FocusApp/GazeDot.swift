import AppKit

/// Red dot at the estimated gaze point, for checking calibration. One 18×18 panel that moves (it can
/// cross screens, so one per display isn't needed). Click-through, never key, on every Space.
/// It is the one Focus window exempt from `FocusActuator.suppressSyntheticClick`: `ignoresMouseEvents`
/// lets a synthetic click pass through it, and WindowProvider excludes our own windows, so the dot can
/// never become a focus target.
@MainActor
final class GazeDot {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 18, height: 18),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = DotView()
    }

    /// `p` in global CG coordinates; nil hides the dot.
    func show(at p: CGPoint?) {
        guard let p else { panel.orderOut(nil); return }
        let ns = nsPoint(fromCG: p)
        panel.setFrameOrigin(NSPoint(x: ns.x - 9, y: ns.y - 9))
        panel.orderFrontRegardless()
    }

    private final class DotView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.systemRed.setFill(); path.fill()
            NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
        }
    }
}
