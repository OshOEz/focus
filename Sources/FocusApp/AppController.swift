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
    /// Owns every setup file and picks which one the engine uses (spec §7); the only thing that touches
    /// `engine.load`/`SetupStore.save` besides this file's own resolver construction in `start()`.
    /// Built in `start()`, not `init`: their closures capture `self`, which two-phase init disallows
    /// while any other stored property (declared below this one) is still unassigned.
    @ObservationIgnored var resolver: SetupResolver!
    @ObservationIgnored var setups: SetupController!
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
    /// Set only when `startCalibration` was reached through `SetupController.calibrate`; forwarded the
    /// finished (or, on cancel, empty) result instead of `calibrationEnded` storing it itself.
    @ObservationIgnored private var calibrationCompletion: (([String: DisplayCalibration]) -> Void)?
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
        // Starts empty: SetupController.start()'s first resolveNow() loads whichever setup matches (or
        // none, until the place is calibrated) — this file no longer picks a calibration itself.
        let engine = FocusEngine(calibrations: [:], settings: settings.engine)
        self.engine = engine
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
        let resolver = SetupResolver(store: SetupStore(directory: AppPaths.setups), engine: engine)
        self.resolver = resolver
        setups = SetupController(
            resolver: resolver, displays: displayProvider, notifier: notifier,
            cameraID: { [weak self] in CameraCapture.pick(CameraCapture.devices(), preferred: self?.settings.cameraID)?.id },
            calibrate: { [weak self] keys, done in self?.startCalibration(keys ?? [], completion: done) },
            noticesEnabled: { [weak self] in self?.noticesEnabled ?? false }
        )
        // A switch/new-place notice or a manual pick changes calibratedDisplays and the menu: same refresh path.
        setups.onChange = { [weak self] in self?.updateStatus(); self?.statusItem?.update() }
        setups.start()   // before the state below is first computed, so needsCalibration reflects the resolved setup
        statusItem = StatusItemController(app: self)
        notifier.onOpen = { [weak self] n in self?.open(n) }
        notifier.onChange = { [weak self] in self?.statusItem?.update() }
        displaysChanged()
        displayProvider.onChange = { [weak self] in
            self?.displaysChanged()
            self?.setups.environmentMayHaveChanged()
        }
        system.onChange = { [weak self] suspended in
            self?.conditions.suspended = suspended
            // Wi-Fi and screens often change while asleep/locked: re-resolve on the way back instead of
            // waiting for the next unrelated trigger.
            if suspended { self?.setups.saveNow() } else { self?.setups.environmentMayHaveChanged() }
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
        if settings.cameraID != old.cameraID {
            stopCamera()   // the next start opens the new device
            setups.environmentMayHaveChanged()
        }
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

    /// Onboarding's Calibrate step: the very first run has no active setup yet (nothing has matched or been
    /// created), so start one; every later visit (redoing the step, or a fresh launch that already matched
    /// a place) recalibrates whichever setup is active.
    func calibrateOrRecalibrate() {
        if resolver.activeID == nil { setups.calibrateThisPlace() } else { setups.recalibrate() }
    }

    /// `completion`, when given (SetupController's calibration hand-off), receives the finished screens
    /// instead of this file storing them: see `calibrationEnded`.
    func startCalibration(_ keys: [String], completion: (([String: DisplayCalibration]) -> Void)? = nil) {
        guard canCalibrate else { completion?([:]); return }
        // #32: every calibration must land in a setup. A menu/Settings call (no `completion`) with no
        // active setup would otherwise finish and have nowhere to store its results — silently losing the
        // work. Delegate to the same path "New place detected"/Setup ▸ use: it creates a setup for this
        // place and calibrates whatever that setup is still missing (so `keys` is moot here: a brand-new
        // setup's screens are all unmapped anyway).
        guard completion != nil || resolver.activeID != nil else { return setups.calibrateThisPlace() }
        calibrationCompletion = completion
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

    /// Only a finished run produces anything (empty on cancel). Storing it — merging into the target setup and
    /// reloading the engine — is `SetupResolver.storeCalibrations`'s job, not this file's: reached either through
    /// `completion` (SetupController started this run) or, for a plain menu/onboarding recalibration, straight
    /// into whichever setup is active.
    private func calibrationEnded(_ run: CalibrationRun) {
        calibration = nil
        syncClickSuppression()
        if onboardingOpen { onboardingWindow?.makeKeyAndOrderFront(nil) }   // back to the guide's calibrate step
        let result = run.phase == .finished ? run.results : [:]
        if let completion = calibrationCompletion {
            calibrationCompletion = nil
            completion(result)
        } else if !result.isEmpty, let id = resolver.activeID {
            do { try resolver.storeCalibrations(result, into: id) } catch {
                log.error("Saving calibration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        updateStatus()
    }

    /// What the engine learned from clicks belongs to the active setup; `SetupResolver.saveActive` is the
    /// only thing that writes it. Guarded so an idle 5-min tick or pause doesn't attempt a write for nothing.
    func saveLearned() {
        guard learnedDirty, !options.smoke else { return }   // bench mode writes nothing
        setups.saveNow()
        learnedDirty = false
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

    /// Ruling 8: while the resolver is auto-matching (no manual pick), a display/layout notice would fire
    /// alongside — or just before — "New place detected"/a setup switch, and (being keyed by display, not by
    /// setup) never gets swept once the engine pauses with empty calibrations. Both notices only make sense
    /// once a manual pick (`overrideID`) has taken the resolver out of that loop.
    private func noticeDisplays(old: [DisplayFingerprint]) {
        guard noticesEnabled, resolver.overrideID != nil else { return }
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
            // Also swept the moment the resolver goes back to auto-matching (ruling 8): a display notice
            // posted under a manual pick would otherwise survive the pick being dropped.
            case .newDisplay(let k):
                if !present.contains(k) || calibratedKeys.contains(k) || resolver.overrideID == nil { notifier.take(n) }
            case .layoutChanged, .setupSwitched: break
            case .newPlace: if resolver.activeID != nil { notifier.take(n) }   // matched or just calibrated
            }
        }
        guard noticesEnabled else { return }
        let cals = engine.calibrations.filter { drifting.contains($0.key) }
        for k in NotificationPolicy.drifted(cals, notified: driftNotified) {
            driftNotified.insert(k)
            notifier.post(.drift(k), name: names[k])
        }
    }

    /// A clicked notification or menu notice. The display/layout/new-place ones need a calibration, so they
    /// wait (like before) until one can start; `setupSwitched` is purely informational and just dismisses.
    func open(_ n: FocusNotice) {
        switch n {
        case .drift(let k), .newDisplay(let k):
            guard canCalibrate else { return }
            notifier.take(n)
            startCalibration([k])
        case .layoutChanged:
            guard canCalibrate else { return }
            notifier.take(n)
            startCalibration([])
        case .newPlace:
            guard canCalibrate else { return }
            notifier.take(n)
            notifier.newPlaceAction?()
        case .setupSwitched:
            notifier.take(n)
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
