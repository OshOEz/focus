import AppKit
import AVFoundation
import FocusCore
import FocusMac
import GazeKit
import SwiftUI

extension AppController {
    /// One settings window for the app's lifetime, brought to front on every open.
    func showSettings() {
        let window = settingsWindow ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: self)))
            w.title = "Focus Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsClosed() }
            }
            w.center()
            settingsWindow = w
            return w
        }()
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeSettings = front == .current ? nil : front
        }
        settingsVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Same hand-back as the guide and calibration: Focus (LSUIElement) would otherwise stay active and keep
    /// the keyboard. With no app to return to, hide, unless the guide is still open and the user is in it.
    private func settingsClosed() {
        settingsVisible(false)
        if let app = appBeforeSettings { app.activate() } else if onboardingWindow?.isVisible != true { NSApp.hide(nil) }
        appBeforeSettings = nil
    }
}

struct SettingsView: View {
    let app: AppController
    @State private var cameras: [CameraDevice] = []

    var body: some View {
        let e = app.settings.engine
        Form {
            Section("Switching screens") {
                SettingSlider(title: "Switch delay", help: "Brief looks away don't count.",
                              info: "The time you need to stay turned toward another display before the keyboard follows you there. Short feels instant; long lets you peek at a neighbouring display without losing your place.",
                              value: app.binding(\.engine.screenDwell), range: 0.1...1.0, step: 0.05, format: OnboardingView.ms)
                SettingSlider(title: "Turn needed to switch", help: "Where one display hands over to the next.",
                              info: "Places the dividing line between two displays inside the gap that separates their nearest calibration dots. At 50 % it sits halfway. Go lower to switch with less movement, higher if you often read right up to the bezel and don't want that to trigger a switch.",
                              value: app.binding(\.engine.headTurn), range: 0.3...0.7, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" })
            }
            Section("Same screen") {
                SettingToggle(title: "Follow my eyes between windows and panes",
                              help: "Whole windows everywhere; split panes in supported editors and terminals.",
                              info: "On the display you face, focus also moves to the window your eyes settle on, and to a split pane in supported terminals and editors (iTerm2, Terminal, Ghostty, Warp, VS Code, Cursor, Zed, Xcode, JetBrains IDEs and more). Other apps, such as browsers, are treated as single windows. On a one-display setup this is the whole job.",
                              isOn: app.binding(\.engine.windowFocus))
                Group {
                    SettingSlider(title: "Window and pane delay", help: "Resting time before a window or pane takes the keyboard.",
                                  info: "The time your eyes must settle on a different window or pane of the current display before it becomes active. Increase it if focus hops around while you read from pane to pane.",
                                  value: app.binding(\.engine.paneDwell), range: 0.2...1.5, step: 0.05, format: OnboardingView.ms)
                    // This row is `syntheticClickFallback`, the pane click fallback (docs/wiki/Focusing-windows-and-panes.md).
                    SettingToggle(title: "Click a pane that ignores focus requests",
                                  help: "A last resort, only in supported terminals and editors.",
                                  info: "A few terminals and editors refuse to be focused by another app. For those only, Focus sends one click to the centre of the pane, well away from any divider. In an editor that click places the text caret too; disable the option to avoid that.",
                                  isOn: app.binding(\.engine.syntheticClickFallback))
                }
                .disabled(!e.windowFocus)
            }
            Section("Typing") {
                SettingToggle(title: "Hold focus while I type",
                              help: "Typing keeps the current window and pane; another display still takes over a second later.",
                              info: "As long as you keep typing, Focus won't move between windows or panes on this display, so a quick look at a neighbouring pane can't steal your input. Turning to a different display still switches roughly one second after you stop. Focus reads only the time of the last key press, never the key itself.",
                              isOn: app.binding(\.engine.waitWhileTyping))
                SettingSlider(title: "Typing pause", help: "Quiet time after your last key before focus moves again.",
                              info: "The time same-display switching waits once you stop typing. Lengthen it if you stop to think between sentences; shorten it to let focus track your gaze again sooner.",
                              value: app.binding(\.engine.typingPause), range: 1...10, step: 0.5, format: { String(format: "%g s", $0) })
                    .disabled(!e.waitWhileTyping)
            }
            Section("Learning") {
                SettingToggle(title: "Learn from my clicks", help: "Your clicks quietly sharpen the calibration.",
                              info: "You nearly always look at what you click, so every click on the display you face is used as one more calibration sample. Tracking gets more accurate with use and adjusts if your posture shifts. A fresh calibration of a display starts its learning over. Everything stays on this Mac.",
                              isOn: app.binding(\.engine.learnFromClicks))
            }
            Section("Camera") { camera }
            Section("Pointer") {
                SettingToggle(title: "Move the pointer with focus", help: "The pointer jumps along when focus changes display.",
                              info: "When focus lands on another display, the pointer is placed on the newly focused window, so new windows, Spaces and Mission Control appear in front of you. While you are using the mouse, Focus leaves the pointer alone.",
                              isOn: app.binding(\.moveCursor))
            }
            Section("Extras") {
                SettingToggle(title: "Show gaze dot", help: "Marks the spot Focus estimates from your head and eyes.",
                              info: "Shows a small red marker at the position Focus currently estimates. Handy to verify a calibration; switch it off for normal use.",
                              isOn: app.binding(\.showGazeDot))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pause shortcut")
                        Spacer()
                        HotKeyField(app: app)
                        InfoButton("One key combination, working in every app, that stops or restarts tracking. Click the field, then press the new combination; it needs ⌘, ⌥ or ⌃. Press Esc to leave it unchanged.")
                    }
                    Text("Pause or resume from anywhere.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("General") {
                SettingToggle(title: "Open at login", help: "Focus starts with your Mac session.",
                              info: "Adds Focus to your login items, so tracking already runs when you sit down to work.",
                              isOn: app.binding(\.launchAtLogin))
                if let note = app.loginItemNote { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Section("Calibration") { calibration }
            Section("Right now") { LiveReadout(app: app) }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 400, idealHeight: 720, maxHeight: 720)
        .onAppear { cameras = Self.externalCameras() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in cameras = Self.externalCameras() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in cameras = Self.externalCameras() }
    }

    /// nil already means the built-in camera, so built-in devices are not listed twice. Enumeration never prompts.
    private static func externalCameras() -> [CameraDevice] { CameraCapture.devices().filter { !$0.isBuiltIn } }

    private var camera: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Camera", selection: app.binding(\.cameraID)) {
                    Text("Built-in (default)").tag(String?.none)
                    ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                    if let id = app.settings.cameraID, !cameras.contains(where: { $0.id == id }) {
                        Text("\(id): not connected").tag(Optional(id))
                    }
                }
                InfoButton("Tracking is most accurate when the camera looks at you head-on. Use the built-in camera when you sit facing the laptop; otherwise choose the external camera mounted on your main display. Calibrate again after changing cameras. The new choice takes effect the next time the camera starts.")
            }
            Text("Choose the camera in front of you.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Recalibrate All Screens") { app.startCalibration([]) }
                Spacer()
                InfoButton("A calibration maps each display's position to your head and eye direction. Leaning in or back is handled for you; calibrate again after moving the laptop, a display or the camera.")
            }
            ForEach(app.displays, id: \.key) { d in
                let name = app.names[d.key] ?? "Display"
                Button(app.calibratedKeys.contains(d.key) ? "Recalibrate \(name)" : "Calibrate \(name)") { app.startCalibration([d.key]) }
            }
            Text("Tells Focus where each display is from where you sit.").font(.caption).foregroundStyle(.secondary)
        }
        // canCalibrate covers "calibrating", no camera access, paused and no display.
        .disabled(!app.canCalibrate)
    }
}

/// Its own view so the 15 Hz pose updates re-render only this row, not the whole form.
struct LiveReadout: View {
    let app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Facing: \(app.facingKey.flatMap { app.names[$0] } ?? "none") · Yaw \(Self.deg(app.lastPose?.yaw)) · Pitch \(Self.deg(app.lastPose?.pitch)) · \(app.status.title)")
                    .monospacedDigit()
                Spacer()
                InfoButton("Yaw is how far your head turns sideways, pitch how far it tilts up or down, and Facing is the display those angles point to. Each display should show clearly distinct values.")
            }
            Text("Live values from the camera.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// PoseFeature angles are radians.
    static func deg(_ r: Double?) -> String {
        guard let r, r.isFinite else { return "–" }
        return String(format: "%.1f°", r * 180 / .pi)
    }
}

/// Records a new pause shortcut from the next key press while listening.
struct HotKeyField: View {
    let app: AppController
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(monitor == nil ? app.settings.hotKey.label : "Type a shortcut…") {
                monitor == nil ? start() : stop()
            }
            .buttonStyle(.bordered)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
            if n.object as? NSWindow === app.settingsWindow { stop() }
        }
        // The local monitor only sees keys while Settings is key: leaving it listening elsewhere would keep
        // the system-wide pause shortcut unregistered with nothing to bring it back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { n in
            if n.object as? NSWindow === app.settingsWindow { stop() }
        }
    }

    private func start() {
        message = nil
        app.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil   // swallowed: the recorder owns every key while listening
        }
    }

    /// Idempotent; resumes the saved shortcut only if it was listening.
    private func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        app.resumeHotKey()
    }

    private func handle(_ e: NSEvent) {
        let mods = HotKey.carbonModifiers(e.modifierFlags)
        if e.keyCode == 53, mods == 0 { stop(); return }   // Esc keeps the current shortcut
        let spec = HotKeySpec(keyCode: UInt32(e.keyCode), modifiers: mods, key: Self.label(e))
        if !spec.isValid { message = "Add ⌘, ⌥ or ⌃."; return }
        // setHotKey registers it itself, so the stop() below re-registers the same, now-saved combo.
        if !app.setHotKey(spec) {
            app.suspendHotKey()   // setHotKey put the old one back; keep it quiet while still listening
            message = "That shortcut is taken by another app."
            return
        }
        message = nil
        stop()
    }

    /// Function keys, arrows and the like arrive as private-use characters (U+F700…U+F8FF): shown by key code.
    static func label(_ e: NSEvent) -> String {
        if e.keyCode == 49 { return "Space" }
        guard let s = e.charactersIgnoringModifiers?.uppercased(), let u = s.unicodeScalars.first, s.unicodeScalars.count == 1,
              !(0xF700...0xF8FF).contains(u.value), !u.properties.isWhitespace, u.properties.generalCategory != .control
        else { return "Key \(e.keyCode)" }
        return s
    }
}
