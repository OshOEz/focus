import AppKit
import FocusCore
import FocusMac
import GazeKit
import Observation
import os
import QuartzCore
import ServiceManagement

struct LaunchOptions {
    /// Bench mode: no onboarding, login item, hotkey or camera, so an unattended launch has no side effects.
    var smoke: Bool
    init(_ args: [String]) { smoke = args.contains("--smoke") }
}

enum AppPaths {
    /// FOCUS_SUPPORT_DIR points benches at a throwaway folder; users never set it.
    static let support: URL = ProcessInfo.processInfo.environment["FOCUS_SUPPORT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus", isDirectory: true)
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var setups: URL { support.appendingPathComponent("setups", isDirectory: true) }
}

private let log = Logger(subsystem: "fr.osho.focus", category: "app")

/// CG global (top-left origin, y down) → AppKit global (bottom-left of the primary screen, y up).
func nsPoint(fromCG p: CGPoint) -> NSPoint {
    NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
}

/// The NSScreen whose CGDisplayBounds equals `frame` (DisplayInfo.frame is CGDisplayBounds).
func nsScreen(forCG frame: CGRect) -> NSScreen? {
    NSScreen.screens.first {
        guard let n = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayBounds(CGDirectDisplayID(n.uint32Value)) == frame
    }
}

/// Owns every component and folds their events into one `AppConditions` → `AppStatus` (FocusCore, unit-tested).
/// One isolation domain: state, engine and providers all live on the MainActor. Only CoreML (inside
/// GazeTracker), model loading and the blocking camera `start()`/`stop()` run elsewhere.
@MainActor @Observable
final class AppController {
    private(set) var status: AppStatus = .needsCamera
    private(set) var settings: AppSettings
    private(set) var conditions = AppConditions()
    private(set) var displays: [DisplayInfo] = []
    private(set) var names: [String: String] = [:]
    private(set) var calibratedKeys: Set<String> = []
    private(set) var lastPose: PoseFeature?
    private(set) var facingKey: String?
    private(set) var gazePoint: CGPoint?
    private(set) var cameraPermission: Permissions.Status = .notDetermined
    private(set) var accessibilityPermission: Permissions.Status = .notDetermined
    private(set) var calibration: CalibrationWindowController?
    /// Why the login item isn't what the toggle says (register error, or approval pending in System Settings).
    private(set) var loginItemNote: String?

    @ObservationIgnored let options: LaunchOptions
    @ObservationIgnored let engine: FocusEngine
    @ObservationIgnored let displayProvider: DisplayProvider
    @ObservationIgnored let windowProvider: WindowProvider
    @ObservationIgnored let paneProvider: PaneProvider
    @ObservationIgnored let actuator: FocusActuator
    @ObservationIgnored let input = InputMonitor()
    @ObservationIgnored let system = SystemStateMonitor()
    @ObservationIgnored private let settingsStore = SettingsStore(url: AppPaths.settings)
    @ObservationIgnored private let setupStore = SetupStore(directory: AppPaths.setups)
    @ObservationIgnored private var setup: Setup
    @ObservationIgnored private var statusItem: StatusItemController?
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var tracker: GazeTracker?
    /// The running camera session; its value is the tracker it opened (nil if none), so a stop can wait
    /// for a session that is still opening the camera and then close exactly what it opened.
    @ObservationIgnored private var cameraTask: Task<GazeTracker?, Never>?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    /// Bumped on every stop: a stream that ends *after* we stopped it must not be taken for a lost camera.
    @ObservationIgnored private var cameraGeneration = 0
    @ObservationIgnored private var nextCameraRetry = 0.0
    @ObservationIgnored private var lastFaceTime = -Double.infinity
    @ObservationIgnored private var lastFocusedWindow: UInt32?
    @ObservationIgnored private var learnedDirty = false
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var onboardingWindow: NSWindow?
    /// The app that had the keyboard when the guide opened; it gets it back when the guide closes.
    @ObservationIgnored var appBeforeOnboarding: NSRunningApplication?
    @ObservationIgnored private var onboardingOpen = false
    @ObservationIgnored var settingsWindow: NSWindow?
    /// The app that had the keyboard when Settings opened; it gets it back when Settings closes.
    @ObservationIgnored var appBeforeSettings: NSRunningApplication?
    @ObservationIgnored private var settingsOpen = false
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private lazy var gazeDot = GazeDot()
    /// Drifted displays already warned about; a display leaves the set once it no longer drifts
    /// (recalibrated), so a later drift warns again. In memory: after a relaunch one reminder is fine.
    @ObservationIgnored private var driftNotified: Set<String> = []
    /// Fingerprints at the previous display change, for NotificationPolicy.layoutChanged.
    @ObservationIgnored private var lastFingerprints: [DisplayFingerprint] = []

    init(options: LaunchOptions) {
        self.options = options
        let settings = SettingsStore(url: AppPaths.settings).load()
        self.settings = settings
        let dp = DisplayProvider()
        displayProvider = dp
        // ponytail: one setup, re-fingerprinted on each save. Plan 5 replaces this with SetupMatcher + EnvironmentFingerprinter.
        let setup = SetupStore(directory: AppPaths.setups).loadAll().first
            ?? Setup(id: UUID(), name: "Default",
                     fingerprint: Fingerprint(displays: dp.fingerprints, cameraID: settings.cameraID ?? "default", wifiSSID: nil),
                     calibrations: [:])
        self.setup = setup
        engine = FocusEngine(calibrations: setup.calibrations, settings: settings.engine)
        let wp = WindowProvider()
        windowProvider = wp
        let pp = PaneProvider(windows: wp)
        paneProvider = pp
        actuator = FocusActuator(windows: wp, panes: pp)
        actuator.moveCursor = settings.moveCursor
        actuator.syntheticClickFallback = settings.engine.syntheticClickFallback
        actuator.paneBoundaryMargin = settings.engine.paneBoundaryMargin
    }

    func start() {
        statusItem = StatusItemController(app: self)
        notifier.onOpen = { [weak self] n in self?.open(n) }
        notifier.onChange = { [weak self] in self?.statusItem?.update() }
        displaysChanged()
        displayProvider.onChange = { [weak self] in self?.displaysChanged() }
        system.onChange = { [weak self] suspended in
            self?.conditions.suspended = suspended
            if suspended { self?.saveLearned() }
            self?.updateStatus()
        }
        conditions.suspended = system.isSuspended   // a login item can start on a locked screen
        input.onClick = { [weak self] p, t in self?.click(at: p, time: t) }
        input.start()
        if !options.smoke {
            registerHotKey(settings.hotKey)
            applyLoginItemDefault()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshPermissions()
        if !settings.onboardingCompleted && !options.smoke { showOnboarding() }
    }

    // MARK: status

    /// Status reads only (never a request): AXIsProcessTrusted and AVCaptureDevice.authorizationStatus.
    func refreshPermissions() {
        let wasAX = accessibilityPermission
        cameraPermission = Permissions.camera
        accessibilityPermission = Permissions.accessibility
        // Global mouse monitors installed before the grant receive nothing: reinstall once it arrives (A6).
        if wasAX != .granted, accessibilityPermission == .granted { input.stop(); input.start() }
        updateStatus()
    }

    func updateStatus() {
        conditions.cameraGranted = cameraPermission == .granted
        conditions.accessibilityGranted = accessibilityPermission == .granted
        conditions.displayCount = displays.count
        calibratedKeys = Set(displays.map(\.key).filter { engine.calibrations[$0] != nil })
        conditions.calibratedDisplays = calibratedKeys.count
        conditions.windowFocus = settings.engine.windowFocus
        conditions.calibrating = calibration != nil
        conditions.faceSeen = CACurrentMediaTime() - lastFaceTime < 1
        conditions.facing = facingKey.flatMap { names[$0] }
        conditions.driftDisplay = driftKeys().sorted().first.flatMap { names[$0] }
        if !conditions.wantsCamera { conditions.cameraAvailable = true }   // judged afresh at the next start
        applyCamera()
        noticeDrift()
        let new = AppStatus(conditions)
        if new != status { status = new; statusItem?.update() }
    }

    func driftKeys() -> Set<String> {
        Set(displays.map(\.key).filter { engine.calibrations[$0]?.needsRecalibration == true })
    }

    private func tick() {
        refreshPermissions()
        ticks += 1
        if ticks % 300 == 0 { saveLearned() }   // every 5 min; also saved on pause, lock and quit
    }

    // MARK: camera

    private func applyCamera() {
        if conditions.wantsCamera {
            if cameraTask == nil, CACurrentMediaTime() >= nextCameraRetry { startCamera() }
        } else {
            stopCamera()
        }
    }

    private func startCamera() {
        guard !options.smoke else { return }
        let generation = cameraGeneration
        let previousStop = stopping
        // Every (re)start follows a gap without samples (pause, lock, permission): drop the dwell, smoothing
        // and action latch, or a latch from before the pause would swallow the first switch after it.
        engine.load(engine.calibrations)
        cameraTask = Task {
            await previousStop?.value   // never start while the previous session is still stopping
            return await self.runCamera(generation)
        }
    }

    /// Runs on the MainActor (the Task inherits it), so samples reach `handle` there; CoreML runs in
    /// GazeTracker's own detached loop.
    private func runCamera(_ generation: Int) async -> GazeTracker? {
        if tracker == nil { tracker = await makeTracker() }
        guard let t = tracker, !Task.isCancelled else { cameraEnded(generation); return tracker }
        t.cameraID = settings.cameraID
        // start() blocks its caller until the capture session runs (hundreds of ms): never on the MainActor.
        let stream = try? await Task.detached { try await t.start() }.value
        guard let stream, !Task.isCancelled else { cameraEnded(generation); return t }
        conditions.cameraAvailable = true
        for await s in stream { handle(s) }
        cameraEnded(generation)
        return t
    }

    /// Loads both CoreML models (slow) off the MainActor.
    private func makeTracker() async -> GazeTracker? {
        guard let t = try? await Task.detached(operation: { try GazeTracker() }).value else { return nil }
        // Called on the capture session queue: never call back into the tracker from here, only hop to
        // the MainActor. CameraCapture retries an unplugged or interrupted camera by itself.
        t.onCameraState = { [weak self] state in
            Task { @MainActor in self?.cameraStateChanged(state) }
        }
        return t
    }

    private func cameraStateChanged(_ state: CameraState) {
        guard cameraTask != nil else { return }   // stale report from a session we already stopped
        conditions.cameraAvailable = state == .running
        updateStatus()
    }

    private func cameraEnded(_ generation: Int) {
        guard generation == cameraGeneration else { return }   // we stopped it on purpose
        cameraTask = nil
        conditions.cameraAvailable = false
        nextCameraRetry = CACurrentMediaTime() + 3   // no models, busy camera or stream ended: retry every 3 s, never spin
        updateStatus()
    }

    private func stopCamera() {
        guard let task = cameraTask else { return }
        cameraGeneration += 1
        cameraTask = nil
        task.cancel()
        // Waits for the session to wind down (it may still be opening the camera), then stops what it
        // opened. stop() blocks on the capture queue: detached, never on the MainActor.
        stopping = Task.detached { await task.value?.stop() }
        lastFaceTime = -.infinity
        facingKey = nil
        gazePoint = nil
        gazeDot.show(at: nil)
    }

    // MARK: samples

    private func handle(_ s: GazeSample) {
        if s.hasFace, s.confidence >= settings.engine.minConfidence {
            let wasSeen = conditions.faceSeen
            lastFaceTime = s.time
            lastPose = s.pose
            if !wasSeen { updateStatus() }
        }
        if let calibration { calibration.add(s); return }
        guard conditions.engineActive else { return }
        let world = currentWorld()
        noteFocus(world)
        if let action = engine.decide(s, world: world, input: input.activity) {
            _ = actuator.perform(action, world: world)
        }
        gazePoint = engine.lastGazePoint
        if settings.showGazeDot { gazeDot.show(at: gazePoint) }
        var facing: String?
        if case .facing(let key) = engine.status { facing = key }
        if facing != facingKey { facingKey = facing; updateStatus() }
    }

    func currentWorld() -> World {
        let focused = windowProvider.focusedWindowID()
        // paneProvider.panes(of:) itself returns [] for a disallowed app (PaneApps.isAllowed), so
        // this only pays for an AX walk when pane focus is on and the focused app opts in.
        let panes = settings.engine.paneFocus ? (focused.map(paneProvider.panes(of:)) ?? []) : []
        // One pane is no split: skip the focused-element round trip that would find it.
        let focusedPane = panes.count > 1 ? focused.flatMap { paneProvider.focusedPaneIndex(of: $0, panes: panes) } : nil
        return World(displays: displays, windows: windowProvider.windows(), focusedWindowID: focused,
                     panes: panes, focusedPane: focusedPane)
    }

    /// Feeds the actuator's per-display "last window" history from every focus change, including the
    /// user's own clicks: the actuator only looks when it acts, and `windowToRestore` prefers that entry,
    /// so without this a glance back would restore the window used before the user clicked another one.
    private func noteFocus(_ world: World) {
        guard let id = world.focusedWindowID, id != lastFocusedWindow,
              let w = world.windows.first(where: { $0.id == id }),
              let d = world.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) })
        else { return }
        lastFocusedWindow = id
        actuator.noteFocusChange(windowID: id, display: d.key)
    }

    private func click(at p: CGPoint, time: Double) {
        guard settings.engine.learnFromClicks, conditions.engineActive else { return }
        if engine.recordClick(at: p, time: time, world: currentWorld()) {
            learnedDirty = true
            updateStatus()   // drift may have appeared
        }
    }

    // MARK: commands

    func togglePause() {
        conditions.userPaused.toggle()
        if conditions.userPaused { saveLearned() }
        updateStatus()   // resuming restarts the camera, which resets the engine's latch (startCamera)
    }

    func onboardingVisible(_ open: Bool) {
        onboardingOpen = open
        syncClickSuppression()
    }

    func settingsVisible(_ open: Bool) {
        settingsOpen = open
        syncClickSuppression()
    }

    /// Our own windows (calibration, setup guide, settings) can catch the click fallback's synthetic click themselves.
    private func syncClickSuppression() {
        actuator.suppressSyntheticClick = calibration != nil || onboardingOpen || settingsOpen
    }

    /// The single write path for settings: apply to the live components, persist, re-derive status.
    func update(_ change: (inout AppSettings) -> Void) {
        let old = settings
        change(&settings)
        guard settings != old else { return }
        engine.settings = settings.engine
        actuator.moveCursor = settings.moveCursor
        actuator.syntheticClickFallback = settings.engine.syntheticClickFallback
        actuator.paneBoundaryMargin = settings.engine.paneBoundaryMargin
        if settings.cameraID != old.cameraID { stopCamera() }   // the next start opens the new device
        if settings.launchAtLogin != old.launchAtLogin { applyLoginItem(settings.launchAtLogin) }
        if !settings.showGazeDot { gazeDot.show(at: nil) }
        updateStatus()
        // Before this, every screen was uncalibrated on purpose (noticesEnabled was false): announce
        // whichever ones are still unmapped now that the guide is done, instead of waiting for the next
        // physical display change to say so.
        if settings.onboardingCompleted, !old.onboardingCompleted { noticeDisplays(old: lastFingerprints) }
        guard !options.smoke else { return }   // bench mode writes nothing
        do { try settingsStore.save(settings) } catch {
            // ponytail: logged only, AppStatus has no "can't save" slot; the next change retries the write.
            log.error("Saving settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func registerHotKey(_ spec: HotKeySpec) {
        hotKey = nil   // unregister first: re-registering the same combo would fail
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.togglePause() }
        }
    }

    /// Registers the new shortcut; if another app holds it, the old one is put back and nothing is saved.
    func setHotKey(_ spec: HotKeySpec) -> Bool {
        guard spec.isValid else { return false }
        registerHotKey(spec)
        guard hotKey != nil else { registerHotKey(settings.hotKey); return false }
        update { $0.hotKey = spec }
        return true
    }

    /// While the recorder listens: a registered Carbon hotkey would swallow its own combo before the recorder sees it.
    func suspendHotKey() { hotKey = nil }

    func resumeHotKey() {
        guard !options.smoke else { return }
        registerHotKey(settings.hotKey)
    }

    /// A paused Focus sends no samples (wantsCamera is false), so a calibration started then could never finish.
    var canCalibrate: Bool { calibration == nil && conditions.cameraGranted && !conditions.userPaused && !displays.isEmpty }

    func startCalibration(_ keys: [String]) {
        guard canCalibrate else { return }
        let keys = keys.isEmpty ? displays.map(\.key) : keys.filter { k in displays.contains { $0.key == k } }
        let targets = CalibrationLayout.targets(for: displays)
        let screens = keys.map { CalibrationRun.Screen(key: $0, targets: targets[$0] ?? []) }
        let connected = Set(displays.map(\.key))
        let others = engine.calibrations.filter { !keys.contains($0.key) && connected.contains($0.key) }.mapValues(\.pose)
        calibration = CalibrationWindowController(
            run: CalibrationRun(screens: screens, others: others, minConfidence: settings.engine.minConfidence),
            frames: Dictionary(uniqueKeysWithValues: displays.map { ($0.key, $0.frame) }), names: names
        ) { [weak self] run in self?.calibrationEnded(run) }
        gazeDot.show(at: nil)   // samples go to the calibration now, so the dot would freeze in place
        syncClickSuppression()
        updateStatus()   // .calibrating → wantsCamera
    }

    /// Only a finished run changes anything. New calibrations replace old ones (and their learned clicks) per screen.
    private func calibrationEnded(_ run: CalibrationRun) {
        calibration = nil
        syncClickSuppression()
        if onboardingOpen { onboardingWindow?.makeKeyAndOrderFront(nil) }   // back to the guide's calibrate step
        var all = engine.calibrations
        for (k, c) in run.results where run.phase == .finished { all[k] = c }
        // Also on cancel: resets the latch, so an action latched before the calibration can't swallow the first switch.
        engine.load(all)
        if run.phase == .finished, !run.results.isEmpty {
            learnedDirty = true
            saveLearned()
        }
        updateStatus()
    }

    /// The engine holds the setup's calibrations plus what it learned from clicks: it is the source of truth.
    /// Stays dirty until a write succeeds, so a failed save is retried at the next pause, lock, 5-min tick or quit.
    func saveLearned() {
        guard learnedDirty, !options.smoke else { return }   // bench mode writes nothing
        setup.calibrations = engine.calibrations
        setup.fingerprint = Fingerprint(displays: displayProvider.fingerprints, cameraID: settings.cameraID ?? "default", wifiSSID: nil)
        do {
            try setupStore.save(setup)
            learnedDirty = false
        } catch {
            // ponytail: logged only, AppStatus has no "can't save" slot.
            log.error("Saving calibrations failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func displaysChanged() {
        let oldFingerprints = lastFingerprints
        lastFingerprints = displayProvider.fingerprints
        displays = displayProvider.displays
        let raw = displays.map { displayProvider.name(for: $0.key) }
        names = Dictionary(uniqueKeysWithValues: zip(displays.map(\.key), DisplayNaming.unique(raw)))
        // Screens changed under a running calibration: its targets and windows are stale. Cancel it; nothing is saved.
        calibration?.cancel()
        updateStatus()
        noticeDisplays(old: oldFingerprints)
        statusItem?.update()
    }

    // MARK: notices

    /// Before the guide is done every screen is uncalibrated on purpose, so there is nothing to announce yet.
    private var noticesEnabled: Bool { settings.onboardingCompleted && !options.smoke }

    private func noticeDisplays(old: [DisplayFingerprint]) {
        guard noticesEnabled else { return }
        let fresh = NotificationPolicy.newDisplays(present: displays.map(\.key), calibrated: calibratedKeys,
                                                   notified: settings.notifiedDisplays)
        for k in fresh { notifier.post(.newDisplay(k), name: names[k]) }
        if !fresh.isEmpty { update { $0.notifiedDisplays.formUnion(fresh) } }
        if !calibratedKeys.isEmpty, NotificationPolicy.layoutChanged(from: old, to: lastFingerprints) {
            notifier.post(.layoutChanged, name: nil)
        }
    }

    /// Sweeps every notice that no longer applies (unplugged, calibrated since, or no longer drifting) and
    /// posts fresh drift notices. Runs from updateStatus(), so a calibration done via Recalibrate ▸ All
    /// Screens or the guide clears its notice immediately, not just on the next physical display change.
    private func noticeDrift() {
        let drifting = driftKeys()
        driftNotified.formIntersection(drifting)
        let present = Set(displays.map(\.key))
        for n in notifier.pending {
            switch n {
            case .drift(let k): if !drifting.contains(k) { notifier.take(n) }
            case .newDisplay(let k): if !present.contains(k) || calibratedKeys.contains(k) { notifier.take(n) }
            case .layoutChanged: break
            }
        }
        guard noticesEnabled else { return }
        let cals = engine.calibrations.filter { drifting.contains($0.key) }
        for k in NotificationPolicy.drifted(cals, notified: driftNotified) {
            driftNotified.insert(k)
            notifier.post(.drift(k), name: names[k])
        }
    }

    /// A clicked notification or menu notice: the fix is always a calibration.
    func open(_ n: FocusNotice) {
        guard canCalibrate else { return }   // e.g. paused: keep the notice until it can be acted on
        notifier.take(n)
        switch n {
        case .drift(let k), .newDisplay(let k): startCalibration([k])
        case .layoutChanged: startCalibration([])
        }
    }

    /// Only the Setup Guide's final button calls this: never at launch, never in bench mode.
    func requestNotificationPermission() {
        guard !options.smoke else { return }
        Task { await notifier.requestAuthorization() }
    }

    /// SMAppService needs a real bundle (not `swift run`), and benches must never touch the login items.
    private var canManageLoginItem: Bool { Bundle.main.bundleIdentifier != nil && !options.smoke }

    /// "On" by default, registered once: after that only the user's toggle registers or unregisters, so
    /// switching Focus off in System Settings → Login Items is never undone behind their back.
    private func applyLoginItemDefault() {
        guard canManageLoginItem, settings.launchAtLogin, !settings.loginItemDefaultApplied else { return }
        try? SMAppService.mainApp.register()
        if SMAppService.mainApp.status == .requiresApproval { loginItemNote = Self.approveLoginItem }
        update { $0.loginItemDefaultApplied = true }
    }

    private static let approveLoginItem = "Approve Focus in System Settings → General → Login Items."

    private func applyLoginItem(_ on: Bool) {
        guard canManageLoginItem else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemNote = SMAppService.mainApp.status == .requiresApproval ? Self.approveLoginItem : nil
        } catch {
            loginItemNote = error.localizedDescription
        }
    }
}
