import AppKit
import FocusCore
import QuartzCore

/// Borderless, always-on-top window that shows one screen's calibration at a time. `canBecomeKey`/`canBecomeMain`
/// are overridden because borderless windows refuse key status otherwise, and without key status Space/Esc
/// would never reach `keyDown`.
private final class CalibrationWindow: NSWindow {
    weak var controller: CalibrationWindowController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: controller?.spacePressed()   // Space
        case 53: controller?.cancel()          // Esc
        default: break                         // swallow everything else: no beep, nothing reaches other apps
        }
    }
}

/// Draws the current phase of the controller's `CalibrationRun`. Reads `run`/`now` at draw time only;
/// it keeps no state of its own.
private final class CalibrationView: NSView {
    weak var controller: CalibrationWindowController?
    override var isFlipped: Bool { true }   // local y-down, so targets map directly to view points

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.96, alpha: 1).setFill()
        bounds.fill()
        guard let c = controller else { return }
        let run = c.run
        switch run.phase {
        case .ready(let i):
            drawText(title: "Screen \(i + 1) of \(run.screens.count) · \(c.name(for: i))",
                     body: "Sit the way you usually work and face this screen with your head and eyes.",
                     action: "Press Space, then follow the red dot until it stops.",
                     footer: "Esc stops the calibration.")
        case .dot(let i, let k, _):
            if let dot = run.dot(at: CACurrentMediaTime()) {
                let p = CGPoint(x: dot.point.x * bounds.width, y: dot.point.y * bounds.height)
                drawDot(at: p, progress: dot.progress)
            }
            drawCaption("\(c.name(for: i)) · dot \(k + 1) of \(run.screens[i].targets.count)")
        case .failed(_, .noFace):
            drawText(title: "Focus couldn't find your face",
                      body: "Check the lighting and that nothing covers the camera.",
                      action: "Press Space to redo this screen, or Esc to stop.", footer: nil)
        case .failed(_, .screensLookedSame):
            drawText(title: "These screens look the same from the camera",
                      body: "Turn your head toward each screen, not only your eyes.",
                      action: "Press Space to start over, or Esc to stop.", footer: nil)
        case .finished, .cancelled:
            break   // the window is ordered out before this would ever be drawn
        }
    }

    private func drawDot(at p: CGPoint, progress: Double) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)).fill()
        let ring = NSBezierPath()
        ring.appendArc(withCenter: p, radius: 18, startAngle: 0, endAngle: 360 * progress, clockwise: false)
        ring.lineWidth = 2
        NSColor.systemRed.setStroke()
        ring.stroke()
    }

    /// Centred title/body/action, with an optional small footer near the bottom.
    private func drawText(title: String, body: String, action: String, footer: String?) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        draw(title, at: CGPoint(x: center.x, y: center.y - 60), font: .systemFont(ofSize: 28), color: .black)
        draw(body, at: CGPoint(x: center.x, y: center.y - 10), font: .systemFont(ofSize: 17), color: .black)
        draw(action, at: CGPoint(x: center.x, y: center.y + 20), font: .systemFont(ofSize: 17), color: .black)
        if let footer { draw(footer, at: CGPoint(x: center.x, y: bounds.maxY - 40), font: .systemFont(ofSize: 13), color: .darkGray) }
    }

    private func drawCaption(_ s: String) {
        draw(s, at: CGPoint(x: bounds.midX, y: bounds.maxY - 40), font: .systemFont(ofSize: 13), color: .darkGray)
    }

    private func draw(_ s: String, at point: CGPoint, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let attributed = NSAttributedString(string: s, attributes: attrs)
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
}

/// One borderless window at a time, moved to whichever screen the run is currently calibrating. The view
/// reads `run`/the clock at draw time; this controller owns the only mutable copy of `run`.
@MainActor final class CalibrationWindowController {
    private(set) var run: CalibrationRun
    private let onEnd: (CalibrationRun) -> Void
    private let frames: [String: CGRect]
    private let names: [String: String]
    private var ended = false
    private var timer: Timer?
    private let window: CalibrationWindow
    private let view: CalibrationView
    private var shownScreen: Int?
    /// The app frontmost right before our first `NSApp.activate()`, so we can hand keyboard focus back to
    /// it once the window closes. Captured once, on that first activate; nil means there wasn't one (or it
    /// was already Focus itself), so we hide instead.
    private var previousApp: NSRunningApplication?
    private var capturedPreviousApp = false

    init(run: CalibrationRun, frames: [String: CGRect], names: [String: String], onEnd: @escaping (CalibrationRun) -> Void) {
        self.run = run
        self.frames = frames
        self.names = names
        self.onEnd = onEnd
        window = CalibrationWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(white: 0.96, alpha: 1)
        window.isReleasedWhenClosed = false
        view = CalibrationView()
        window.contentView = view
        window.controller = self
        view.controller = self
        showCurrentScreen()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
    }

    func name(for i: Int) -> String { names[run.screens[i].key] ?? run.screens[i].key }

    func add(_ s: GazeSample) { run.add(s) }

    func spacePressed() {
        run.pressSpace(at: CACurrentMediaTime())
        showCurrentScreen()
    }

    func cancel() {
        run.pressEscape()
        endIfNeeded()
    }

    private func onTick() {
        run.tick(at: CACurrentMediaTime())
        showCurrentScreen()
        view.needsDisplay = true
        endIfNeeded()
    }

    /// The screen index for every phase that shows something; nil once finished/cancelled.
    private func currentScreenIndex() -> Int? {
        switch run.phase {
        case .ready(let i), .dot(let i, _, _), .failed(let i, _): return i
        case .finished, .cancelled: return nil
        }
    }

    /// Moves the window to the screen being calibrated when it changes; leaves every other screen untouched.
    /// `frames`/`nsScreen(forCG:)` are assumed to resolve for every `run.screens[i].key`: both come from the
    /// same display list the caller built the run's screens from (`AppController.startCalibration`).
    private func showCurrentScreen() {
        guard let i = currentScreenIndex(), i != shownScreen else { return }
        shownScreen = i
        guard let frame = frames[run.screens[i].key], let screen = nsScreen(forCG: frame) else { return }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        if !capturedPreviousApp {
            capturedPreviousApp = true
            let front = NSWorkspace.shared.frontmostApplication
            if front != .current { previousApp = front }
        }
        NSApp.activate()   // LSUIElement apps aren't active by default
    }

    private func endIfNeeded() {
        guard !ended, run.phase == .finished || run.phase == .cancelled else { return }
        ended = true
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        // Undo the activate above: Focus (LSUIElement) would otherwise stay the active app and steal
        // keyboard focus from whatever the user was in before calibrating. Skipped if we never actually
        // activated (e.g. an empty run that finished before showing a screen).
        if capturedPreviousApp {
            if let previousApp { previousApp.activate() } else { NSApp.hide(nil) }
        }
        onEnd(run)
    }
}
