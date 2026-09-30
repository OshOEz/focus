import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What the engine itself can tell about tracking, for the menu status line. App-level states
/// (paused, permissions, camera, screen locked) are the app's.
public enum EngineStatus: Equatable, Sendable {
    case needsCalibration          // no connected display has a calibration
    case noFace                    // "Looking for your face"
    case lookingAway               // pose far from every screen: ignored
    case facing(String)            // display key
    case oneDisplayWindowFocusOff  // a single display and same-screen focus off: nothing to switch
}

/// Stops the engine from re-emitting an action that had no visible effect (a screen without a
/// window, a raise the app refused, pane focus not available yet): once emitted, an action stays
/// latched until the engine wants something else or the focused window changes (plan-1 follow-up).
public struct ActionLatch: Sendable {
    private var last: FocusAction?
    private var focusedAtEmit: UInt32?

    public init() {}

    /// `fired`: what the dwell released this frame; `candidate`: what the engine wants now.
    public mutating func admit(_ fired: FocusAction?, candidate: FocusAction?, focused: UInt32?) -> FocusAction? {
        if candidate != last || focused != focusedAtEmit { last = nil }
        guard let fired, fired != last else { return nil }
        last = fired
        focusedAtEmit = focused
        return fired
    }

    public mutating func reset() { last = nil }
}

/// Turns gaze samples into focus actions for one setup (spec §5–8).
/// Deliberately not Sendable: one isolation domain owns it (the app's MainActor controller).
public final class FocusEngine {
    /// Changes apply on the next sample (the Settings window edits this live).
    public var settings: FocusSettings {
        didSet { classifier.headTurn = settings.headTurn; classifier.maxDistance = settings.offScreenMargin }
    }
    /// On by default; `nil` feeds raw samples (unit tests that pin guard timing with ideal steps).
    public var smoother: GazeSmoother? = GazeSmoother()
    public private(set) var calibrations: [String: DisplayCalibration] = [:]
    public private(set) var status: EngineStatus = .noFace
    /// Smoothed pose of the last face sample (Settings live readout).
    public private(set) var lastPose: PoseFeature?
    /// Where the user looks, global CG coordinates, when the faced display has a map (gaze dot).
    public private(set) var lastGazePoint: CGPoint?
    private var classifier: ScreenClassifier
    private var maps: [String: RBFMap] = [:]
    private var dwell = Dwell<FocusAction>()
    private var latch = ActionLatch()
    private var recent: [(sample: GazeSample, display: String)] = []

    public init(calibrations: [String: DisplayCalibration], settings: FocusSettings) {
        self.settings = settings
        classifier = ScreenClassifier(centroids: [:], headTurn: settings.headTurn, maxDistance: settings.offScreenMargin)
        load(calibrations)
    }

    /// Swap in another setup's calibrations.
    public func load(_ calibrations: [String: DisplayCalibration]) {
        self.calibrations = calibrations
        classifier = ScreenClassifier(centroids: calibrations.mapValues(\.pose), clouds: calibrations.mapValues(\.dotPoses),
                                      headTurn: settings.headTurn, maxDistance: settings.offScreenMargin)
        maps = calibrations.compactMapValues(\.map)
        dwell.reset()
        latch.reset()
        smoother?.reset()
        recent.removeAll()
        lastGazePoint = nil
    }

    /// Recalibrating a display replaces its calibration wholesale; what was learned from clicks
    /// goes with it.
    public func setCalibration(_ c: DisplayCalibration, for key: String) {
        var c = c
        c.learnedPoints = []
        c.recentErrors = []
        var all = calibrations
        all[key] = c
        load(all)
    }

    public func decide(_ sample: GazeSample, world: World, input: InputActivity) -> FocusAction? {
        let s = smoother?.smooth(sample) ?? sample
        let now = s.time
        guard world.displays.contains(where: { calibrations[$0.key] != nil }) else { return idle(.needsCalibration) }
        guard s.confidence >= settings.minConfidence, s.raw.x.isFinite, s.raw.y.isFinite else { return idle(.noFace) }
        guard let key = classifier.classify(s.pose),
              let display = world.displays.first(where: { $0.key == key })
        else { return idle(.lookingAway) }
        lastPose = s.pose
        status = world.displays.count == 1 && !settings.windowFocus ? .oneDisplayWindowFocusOff : .facing(key)

        // Kept even when the guards below block, so a click right after moving the mouse can still teach us.
        recent.append((s, key))
        recent.removeAll { now - $0.sample.time > 1 }

        // The RBF returns raw unchanged far from calibration data, so a point just past a
        // display's edge (common near scrollbars/window borders) must be clamped back into it —
        // otherwise it can resolve to a window on the neighboring screen (issue #6). The upper
        // bound is clamped strictly below 1 (not to it) because CGRect.contains excludes maxX
        // but includes minX, so an exact 1.0 would land on the adjacent display's own frame.
        let point = maps[key].map { map -> CGPoint in
            let local = map.map(s.raw)
            let upper = CGFloat(1).nextDown
            return globalPoint(CGPoint(x: min(max(local.x, 0), upper), y: min(max(local.y, 0), upper)), in: display.frame)
        }
        lastGazePoint = point

        let focusedDisplay = world.windows.first { $0.id == world.focusedWindowID }.flatMap { w in
            world.displays.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }?.key
        }
        let trusted = settings.windowFocus && calibrations[key]?.needsRecalibration == false
        var candidate: FocusAction?
        var duration = settings.paneDwell
        if key != focusedDisplay {
            duration = settings.screenDwell
            if input.allowsScreenSwitch(at: now, settings) {
                // land on the window looked at on that screen; otherwise the actuator
                // restores the last window used there.
                let gazed = trusted ? point.flatMap {
                    TargetResolver.window(at: $0, windows: world.windows, current: nil, display: display.frame, settings: settings)
                } : nil
                candidate = gazed.map(FocusAction.window) ?? .display(key)
            }
        } else if trusted, input.allowsSameScreen(at: now, settings), let p = point {
            candidate = sameScreenTarget(at: p, display: display, world: world)
        }
        return latch.admit(dwell.propose(candidate, at: now, duration: duration), candidate: candidate,
                           focused: world.focusedWindowID)
    }

    /// Learns from a click if the gaze was steady on the clicked display just before. Returns true if learned.
    @discardableResult
    public func recordClick(at p: CGPoint, time: Double, world: World) -> Bool {
        let steady = recent.filter { $0.sample.time <= time && time - $0.sample.time <= settings.screenDwell }
        guard settings.learnFromClicks, steady.count >= 3,
              let display = world.displays.first(where: { $0.frame.contains(p) }),
              steady.allSatisfy({ $0.display == display.key }),
              calibrations[display.key] != nil
        else { return false }
        let input = CGPoint(x: median(steady.map { Double($0.sample.raw.x) }),
                            y: median(steady.map { Double($0.sample.raw.y) }))
        calibrations[display.key]!.learn(CalibrationPoint(input: input, target: localPoint(p, in: display.frame)))
        maps[display.key] = calibrations[display.key]!.map
        return true
    }

    private func sameScreenTarget(at p: CGPoint, display: DisplayInfo, world: World) -> FocusAction? {
        if let w = TargetResolver.window(at: p, windows: world.windows, current: world.focusedWindowID,
                                         display: display.frame, settings: settings),
           w != world.focusedWindowID {
            return .window(w)
        }
        if settings.paneFocus, let fw = world.focusedWindowID,
           let i = TargetResolver.pane(at: p, panes: world.panes, display: display.frame, settings: settings),
           i != world.focusedPane {
            return .pane(window: fw, frame: world.panes[i])
        }
        return nil
    }

    private func idle(_ reason: EngineStatus) -> FocusAction? {
        status = reason
        dwell.reset()
        latch.reset()
        lastGazePoint = nil
        lastPose = nil
        return nil
    }
}
