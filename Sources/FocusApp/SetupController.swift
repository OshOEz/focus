import AppKit
import AVFoundation
import FocusCore
import FocusMac

/// Keeps the engine on the right setup as the Mac moves between places (spec §7). SetupResolver decides;
/// this class adds the OS side: triggers, debouncing, names, notifications and the calibration hand-off.
@MainActor
final class SetupController {
    let resolver: SetupResolver
    var onChange: (() -> Void)?

    private let displays: DisplayProvider
    private let notifier: Notifier
    private let cameraID: () -> String?
    private let calibrate: ([String]?, @escaping ([String: DisplayCalibration]) -> Void) -> Void
    /// Same gate as the display/drift notices (`AppController.noticesEnabled`): nothing under `--smoke`,
    /// nothing before the guide is done. Passed in rather than duplicated, so there's one flag, not two.
    private let noticesEnabled: () -> Bool
    private var pending: Task<Void, Never>?
    private var lastSSID: String?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(resolver: SetupResolver, displays: DisplayProvider, notifier: Notifier, cameraID: @escaping () -> String?,
         calibrate: @escaping ([String]?, @escaping ([String: DisplayCalibration]) -> Void) -> Void,
         noticesEnabled: @escaping () -> Bool) {
        self.resolver = resolver; self.displays = displays; self.notifier = notifier
        self.cameraID = cameraID; self.calibrate = calibrate; self.noticesEnabled = noticesEnabled
    }

    func start() {
        resolveNow()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentMayHaveChanged() }
            })
        }
        // ponytail: polls the Wi-Fi name every 15 s instead of CWEventDelegate (no delegate, no queue hop). A
        // Wi-Fi-only place change shows up within 15 s; screens and camera have instant callbacks.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ssid = EnvironmentFingerprinter.wifiSSID()
                if ssid != self.lastSSID { self.lastSSID = ssid; self.environmentMayHaveChanged() }
            }
        }
    }

    /// Display reconfiguration fires several callbacks per change (begin/end, one per screen) and positions settle
    /// over a few hundred ms; reading mid-way would announce a half-applied arrangement as a new place. So wait for
    /// 1 s without triggers.
    func environmentMayHaveChanged() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.resolveNow()
        }
    }

    func resolveNow() {
        guard let camera = cameraID() else { return }   // no camera: AppController already shows "camera off"
        let fp = EnvironmentFingerprinter.current(displays: displays.fingerprints, cameraID: camera)
        lastSSID = fp.wifiSSID
        handle(resolver.resolve(fp))
    }

    func choose(_ id: UUID) { resolver.choose(id); onChange?() }
    func automatic() { handle(resolver.automatic()) }

    /// New place: creates its setup (carrying identical screens over, see SetupResolver.createSetup), then
    /// calibrates the screens still missing, or all of them if everything was carried over.
    func calibrateThisPlace() {
        let base = resolver.current?.wifiSSID ?? NSScreen.screens.map(\.localizedName).joined(separator: " + ")
        var name = base, n = 2
        while resolver.setups.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        let setup: Setup
        do {
            guard let s = try resolver.createSetup(named: name) else { return }
            setup = s
        } catch {
            return alert("Couldn't save the new setup", error.localizedDescription)
        }
        onChange?()
        let missing = displays.displays.map(\.key).filter { setup.calibrations[$0] == nil }
        run(calibrationOf: missing.isEmpty ? nil : missing, into: setup.id)
    }

    func recalibrate() {
        guard let id = resolver.activeID else { return calibrateThisPlace() }
        run(calibrationOf: nil, into: id)
    }

    func saveNow() { try? resolver.saveActive() }

    // MARK: - private

    /// The target setup is captured *now*: if the place changes during calibration, results still land in it.
    private func run(calibrationOf keys: [String]?, into id: UUID) {
        calibrate(keys) { [weak self] result in
            guard let self, !result.isEmpty else { return }
            do { try self.resolver.storeCalibrations(result, into: id) } catch {
                self.alert("Couldn't save the calibration", error.localizedDescription)
            }
            self.onChange?()
        }
    }

    private func handle(_ event: SetupEvent?) {
        if noticesEnabled() {
            switch event {
            case .switched(let id, let ambiguous)?:
                notifier.setupSwitched(to: resolver.setups.first { $0.id == id }?.name ?? "", ambiguous: ambiguous)
            case .newPlace?:
                notifier.newPlaceDetected { [weak self] in self?.calibrateThisPlace() }
            case nil:
                break
            }
        }
        onChange?()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        runModal(a)
    }

    /// Every SetupController modal goes through here: Settings, the guide and calibration all hand the
    /// keyboard back to whichever app had it, and these dialogs (opened from a menu click, so some other
    /// app is usually frontmost) shouldn't be the one place that leaves it stuck on Focus.
    @discardableResult
    private func runModal(_ a: NSAlert) -> NSApplication.ModalResponse {
        let hadFocus = NSWorkspace.shared.frontmostApplication
        NSApp.activate()   // LSUIElement apps aren't active by default
        let response = a.runModal()
        if let hadFocus, hadFocus != .current { hadFocus.activate() }
        return response
    }
}

/// Menu item running a closure; target/action otherwise needs one object per item. No closure-based
/// NSMenuItem existed yet in FocusApp (StatusItemController's own `Action` isn't an NSMenuItem subclass).
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

/// The "Setup ▸" submenu: switch setups, rename/recalibrate/delete, or drop a manual pick.
extension SetupController {
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Setup: \(resolver.active?.name ?? "none")", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let sorted = resolver.setups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for s in sorted {
            let isActive = s.id == resolver.activeID
            let fits = resolver.candidates.contains(s.id) && !isActive
            let row = NSMenuItem(title: s.name + (fits ? " (also fits here)" : ""), action: nil, keyEquivalent: "")
            row.state = isActive ? .on : .off
            let sub = NSMenu()
            if !isActive { sub.addItem(ActionItem("Use This Setup") { [weak self] in self?.choose(s.id) }) }
            sub.addItem(ActionItem("Rename…") { [weak self] in self?.askRename(s) })
            if isActive { sub.addItem(ActionItem("Recalibrate…") { [weak self] in self?.recalibrate() }) }
            sub.addItem(.separator())
            sub.addItem(ActionItem("Delete…") { [weak self] in self?.askDelete(s) })
            row.submenu = sub
            menu.addItem(row)
        }
        if sorted.isEmpty {
            let none = NSMenuItem(title: "No setups yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        if resolver.active == nil, resolver.current != nil {
            menu.addItem(ActionItem("Calibrate This Place…") { [weak self] in self?.calibrateThisPlace() })
        }
        if resolver.overrideID != nil {
            menu.addItem(ActionItem("Choose Automatically") { [weak self] in self?.automatic() })
        }
        item.submenu = menu
        return item
    }

    private func askRename(_ s: Setup) {
        let a = NSAlert()
        a.messageText = "Rename “\(s.name)”"
        let field = NSTextField(string: s.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard runModal(a) == .alertFirstButtonReturn else { return }
        do { try resolver.rename(s.id, to: field.stringValue) } catch { return showError(error) }
        onChange?()
    }

    private func askDelete(_ s: Setup) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete “\(s.name)”?"
        a.informativeText = "Its calibration is lost. If you come back to this place, Focus will ask you to calibrate again."
        a.addButton(withTitle: "Delete").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard runModal(a) == .alertFirstButtonReturn else { return }
        do { handle(try resolver.delete(s.id)) } catch { showError(error) }
    }

    private func showError(_ error: Error) { alert("Couldn't change the setup", error.localizedDescription) }
}
