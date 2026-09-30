import AppKit
import FocusCore
import FocusMac
import SwiftUI

extension AppController {
    /// Settings controls write through `update`, the single settings write path.
    func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    /// One guide window for the app's lifetime. Each open starts over on step 1: a fresh hosting controller
    /// drops the previous `@State` step.
    func showOnboarding() {
        let window = onboardingWindow ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(app: self)))
            w.title = "Welcome to Focus"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // The token is dropped on purpose: the window lives as long as the app, so the observer never
            // needs removing.
            _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onboardingClosed() }
            }
            onboardingWindow = w
            return w
        }()
        if !window.isVisible {
            window.contentViewController = NSHostingController(rootView: OnboardingView(app: self))
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeOnboarding = front == .current ? nil : front
        }
        window.center()
        onboardingVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Same hand-back as the calibration window: Focus (LSUIElement) would otherwise stay active and keep the
    /// keyboard. With no app to return to, hide, unless Settings is still open and the user is in it.
    private func onboardingClosed() {
        onboardingVisible(false)
        if let app = appBeforeOnboarding { app.activate() } else if settingsWindow?.isVisible != true { NSApp.hide(nil) }
        appBeforeOnboarding = nil
    }
}

struct OnboardingView: View {
    let app: AppController
    @State var step: OnboardingStep = .welcome

    private var permissionsGranted: Bool { app.cameraPermission == .granted && app.accessibilityPermission == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption).foregroundStyle(.secondary)
                .padding([.top, .horizontal], 24)
            ScrollView { page.frame(maxWidth: .infinity, alignment: .leading).padding(24) }
            Divider()
            HStack {
                if let previous = step.previous {
                    Button("Back") { step = previous }
                }
                Spacer()
                if !step.canContinue(permissionsGranted: permissionsGranted) {
                    Text("Continue unlocks once both are on.").font(.caption).foregroundStyle(.secondary)
                }
                if let next = step.next {
                    Button("Continue") { step = next }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!step.canContinue(permissionsGranted: permissionsGranted))
                } else {
                    Button("Start Using Focus") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 480)
        // The 1 Hz tick refreshes too; this makes the page update the moment the user returns from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .calibrate: calibrate
        case .adjust: adjust
        case .tryIt: tryIt
        case .done: done
        }
    }

    private func title(_ s: String) -> some View { Text(s).font(.title).bold() }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Your keyboard follows your eyes")
            Text("Face a display, a window or a split pane and your typing goes there. Focus moves the keyboard for you, without a click.")
            Label("Your Mac's camera reads head angle and eye position, locally, with nothing stored.", systemImage: "camera")
            Label("Rest your gaze for a moment and the keyboard follows.", systemImage: "timer")
            Label("It holds still while you type or use the mouse.", systemImage: "keyboard")
        }
    }

    // Requests happen only in these button actions, with a human in front of the guide; never on appear.
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Two switches to flip")
            Text("Focus needs both before it can do anything. You only grant them once.")
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Camera").font(.headline)
                    Text("Used to see which way you face. Each frame is processed and dropped at once; nothing is saved.")
                    switch app.cameraPermission {
                    case .granted: allowed
                    case .notDetermined:
                        Button("Allow Camera") {
                            Task { _ = await Permissions.requestCamera(); app.refreshPermissions() }
                        }
                    case .denied:
                        HStack {
                            Text("Camera access was declined.").foregroundStyle(.secondary)
                            Button("Open Privacy Settings") { Permissions.openSettings(.camera) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility").font(.headline)
                    Text("Lets Focus raise windows, focus panes and place the pointer.")
                    if app.accessibilityPermission == .granted {
                        allowed
                    } else {
                        Button("Allow Accessibility") {
                            Permissions.promptAccessibility()
                            Permissions.openSettings(.accessibility)
                        }
                        Text("In the list that opens, turn Focus on. No need to click anything here afterwards: this step ticks itself off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }

    private var allowed: some View { Text("✓ Allowed").foregroundStyle(.green) }

    private var calibrate: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Map your screens")
            Text("A red dot visits 9 points on each screen, plus a few near the borders it shares with its neighbours. Keep your eyes on it: roughly 20 seconds a screen. Space starts each screen, Esc stops.")
            Text("Sit as you normally do at your desk, so the map matches real use.").foregroundStyle(.secondary)
            if app.displays.isEmpty {
                Text("Focus can't see any screen yet. Use Recalibrate in the menu bar once it can.")
            } else {
                ForEach(app.displays, id: \.key) { d in
                    let name = app.names[d.key] ?? "Display"
                    Text(app.calibratedKeys.contains(d.key) ? "✓ \(name) is mapped" : "\(name): not mapped yet")
                }
                let all = app.displays.allSatisfy { app.calibratedKeys.contains($0.key) }
                Button(all ? "Redo Calibration" : "Start Calibration") { app.startCalibration([]) }
                    .disabled(!app.canCalibrate)
                if app.conditions.userPaused {
                    Text("Focus is paused. Resume it from the menu bar to calibrate.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var adjust: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Fine-tune")
            Text("Most people never touch these. You'll find them again in Settings.")
            SettingSlider(title: "Switch delay", help: "Brief looks away don't count.",
                          info: "The time you need to stay turned toward another display before the keyboard follows you there. Short feels instant; long lets you peek at a neighbouring display without losing your place.",
                          value: app.binding(\.engine.screenDwell), range: 0.1...1.0, step: 0.05, format: Self.ms)
            SettingSlider(title: "Turn needed to switch", help: "Where one display hands over to the next.",
                          info: "Places the dividing line between two displays inside the gap that separates their nearest calibration dots. At 50 % it sits halfway. Go lower to switch with less movement, higher if you often read right up to the bezel and don't want that to trigger a switch.",
                          value: app.binding(\.engine.headTurn), range: 0.3...0.7, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" })
            SettingToggle(title: "Follow my eyes between windows and panes",
                          help: "Whole windows everywhere; split panes in supported editors and terminals.",
                          info: "On the display you face, focus also moves to the window your eyes settle on, and to a split pane in supported terminals and editors (iTerm2, Terminal, Ghostty, Warp, VS Code, Cursor, Zed, Xcode, JetBrains IDEs and more). Other apps, such as browsers, are treated as single windows. On a one-display setup this is the whole job.",
                          isOn: app.binding(\.engine.windowFocus))
        }
    }

    static func ms(_ v: Double) -> String { "\(Int((v * 1000).rounded())) ms" }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Try it")
            Text("Turn from screen to screen. The one you face lights up below, and the red dot marks Focus's estimate of your gaze.")
            if app.calibratedKeys.isEmpty {
                Text("Map at least one screen in the previous step to see it here.").foregroundStyle(.secondary)
            }
            ScreenMapView(app: app).frame(maxWidth: .infinity)
            Text(app.status.title).font(.callout).monospacedDigit()
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Ready")
            Text("From now on Focus stays in the menu bar. The eye icon holds pause, calibration and Settings.")
            Text("\(app.settings.hotKey.label) toggles pause from any app.")
            Text("Nothing else to learn: face what you want to type into.")
        }
    }

    private func finish() {
        app.update { $0.onboardingCompleted = true }
        app.requestNotificationPermission()   // the one place Focus asks: a click, never at launch
        app.onboardingWindow?.close()
    }
}

/// The displays as the engine sees them (CG global frames), with the faced one filled and the gaze dot.
struct ScreenMapView: View {
    let app: AppController

    var body: some View {
        // Snapshot the observed state here: Canvas's renderer is not MainActor-isolated.
        let displays = app.displays, names = app.names, facing = app.facingKey, gaze = app.gazePoint
        Canvas { ctx, size in
            let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull, union.width > 0, union.height > 0 else { return }
            // Uniform scale with 12 pt padding. CG and SwiftUI both have y down, so no flip.
            let s = min((size.width - 24) / union.width, (size.height - 24) / union.height)
            let ox = (size.width - union.width * s) / 2, oy = (size.height - union.height * s) / 2
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + (p.x - union.minX) * s, y: oy + (p.y - union.minY) * s) }
            for d in displays {
                let o = map(d.frame.origin)
                let r = CGRect(x: o.x, y: o.y, width: d.frame.width * s, height: d.frame.height * s)
                let path = Path(roundedRect: r, cornerRadius: 6)
                if d.key == facing { ctx.fill(path, with: .color(Color.accentColor.opacity(0.35))) }
                ctx.stroke(path, with: .style(.secondary))
                ctx.draw(Text(names[d.key] ?? "").font(.caption), at: CGPoint(x: r.midX, y: r.midY))
            }
            if let gaze {
                let c = map(gaze)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.red))
            }
        }
        .frame(width: 420, height: 220)
    }
}

/// An ⓘ button whose popover holds the long explanation of a setting.
struct InfoButton: View {
    let text: String
    @State private var shown = false
    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .popover(isPresented: $shown) { Text(text).frame(width: 300).fixedSize(horizontal: false, vertical: true).padding() }
    }
}

struct SettingSlider: View {
    let title: String, help: String, info: String
    @Binding var value: Double
    let range: ClosedRange<Double>, step: Double
    let format: (Double) -> String
    /// The value while a drag is in progress: `value` writes settings.json, so it is set once on release.
    /// Keyboard steps have no drag and write through directly.
    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(draft ?? value)).monospacedDigit().foregroundStyle(.secondary)
                InfoButton(info)
            }
            Slider(value: Binding(get: { draft ?? value }, set: { v in if draft != nil { draft = v } else { value = v } }),
                   in: range, step: step) { editing in
                if editing { draft = value } else if let d = draft { draft = nil; value = d }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SettingToggle: View {
    let title: String, help: String, info: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(title, isOn: $isOn)
                Spacer()
                InfoButton(info)
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}
