import Foundation
import Testing
@testable import FocusCore

private let L = DisplayInfo(key: "L", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
private let R = DisplayInfo(key: "R", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
private let windows = [
    WindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 800)),
    WindowInfo(id: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 800)),
    WindowInfo(id: 3, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
]
private let world = World(displays: [L, R], windows: windows, focusedWindowID: 1)
private let quiet = InputActivity()
private let noWindowOnR = World(displays: [L, R], windows: Array(windows.prefix(2)), focusedWindowID: 1)

/// Identity calibration: raw gaze already equals the local point.
private func identity(yaw: Double) -> DisplayCalibration {
    let pts = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.9),
               CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.5, y: 0.5)].map { CalibrationPoint(input: $0, target: $0) }
    return DisplayCalibration(pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), calibrationPoints: pts)
}

private func engine() -> FocusEngine {
    let e = FocusEngine(calibrations: ["L": identity(yaw: -0.3), "R": identity(yaw: 0.3)], settings: FocusSettings())
    e.smoother = nil   // these tests pin guard timing with ideal step inputs; smoothing has its own tests
    return e
}

private func sample(_ t: Double, yaw: Double, raw: CGPoint = CGPoint(x: 0.25, y: 0.5), confidence: Double = 1) -> GazeSample {
    GazeSample(time: t, raw: raw, pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), confidence: confidence)
}

@Test func switchesScreenAfterDwell() {
    let e = engine()
    for t in [0, 0.1, 0.2] { #expect(e.decide(sample(t, yaw: 0.3), world: noWindowOnR, input: quiet) == nil) }
    #expect(e.decide(sample(0.35, yaw: 0.3), world: noWindowOnR, input: quiet) == .display("R"))
}

@Test func screenSwitchWaitsOneSecondAfterTyping() throws {
    let e = engine()
    var first: Double?
    for i in 0..<30 where first == nil {
        let t = Double(i) / 10
        if e.decide(sample(t, yaw: 0.3), world: noWindowOnR, input: InputActivity(lastKey: 0)) != nil { first = t }
    }
    #expect((1.3...1.45).contains(try #require(first)))   // 1 s after the keystroke, then the 300 ms dwell
}

@Test func focusesOtherWindowOnSameScreen() {
    let e = engine()
    let raw = CGPoint(x: 0.75, y: 0.5)   // → (750, 400), inside window 2
    #expect(e.decide(sample(0, yaw: -0.3, raw: raw), world: world, input: quiet) == nil)
    #expect(e.decide(sample(0.35, yaw: -0.3, raw: raw), world: world, input: quiet) == .window(2))
}

@Test func focusesOtherPaneOfFocusedWindow() {
    let e = engine()
    var w = world
    w.panes = [CGRect(x: 0, y: 0, width: 250, height: 800), CGRect(x: 250, y: 0, width: 250, height: 800)]
    w.focusedPane = 0
    let raw = CGPoint(x: 0.4, y: 0.5)    // → (400, 400): window 1, pane 1
    #expect(e.decide(sample(0, yaw: -0.3, raw: raw), world: w, input: quiet) == nil)
    #expect(e.decide(sample(0.35, yaw: -0.3, raw: raw), world: w, input: quiet) == .pane(window: 1, frame: w.panes[1]))
}

@Test func lowConfidenceRestartsDwell() {
    let e = engine()
    _ = e.decide(sample(0, yaw: 0.3), world: noWindowOnR, input: quiet)
    _ = e.decide(sample(0.1, yaw: 0.3), world: noWindowOnR, input: quiet)
    #expect(e.decide(sample(0.2, yaw: 0.3, confidence: 0), world: noWindowOnR, input: quiet) == nil)
    #expect(e.decide(sample(0.35, yaw: 0.3), world: noWindowOnR, input: quiet) == nil)
    #expect(e.decide(sample(0.7, yaw: 0.3), world: noWindowOnR, input: quiet) == .display("R"))
}

@Test func unpluggedScreenIsIgnored() {
    let e = engine()
    let onlyL = World(displays: [L], windows: windows, focusedWindowID: 1)
    for t in [0, 0.2, 0.4, 0.6] { #expect(e.decide(sample(t, yaw: 0.3), world: onlyL, input: quiet) == nil) }
}

@Test func clickRightAfterMouseMoveStillLearns() throws {
    let e = engine()
    for t in [0, 0.1, 0.2] {
        var input = InputActivity()
        input.lastMouse = t          // user is moving the mouse: no action…
        #expect(e.decide(sample(t, yaw: -0.3, raw: CGPoint(x: 0.2, y: 0.2)), world: world, input: input) == nil)
    }
    // …but the gaze samples are kept for learning.
    #expect(e.recordClick(at: CGPoint(x: 300, y: 200), time: 0.25, world: world))
    let learned = try #require(e.calibrations["L"]?.learnedPoints)
    #expect(learned == [CalibrationPoint(input: CGPoint(x: 0.2, y: 0.2), target: CGPoint(x: 0.3, y: 0.25))])
}

@Test func clickOnAnotherScreenThanGazeIsNotLearned() {
    let e = engine()
    for t in [0, 0.1, 0.2] { _ = e.decide(sample(t, yaw: 0.3), world: world, input: quiet) }
    #expect(!e.recordClick(at: CGPoint(x: 300, y: 200), time: 0.25, world: world))
}

@Test func offScreenPoseRestartsDwell() {
    let e = engine()
    _ = e.decide(sample(0, yaw: 0.3), world: noWindowOnR, input: quiet)
    _ = e.decide(sample(0.1, yaw: 0.3), world: noWindowOnR, input: quiet)
    #expect(e.decide(sample(0.2, yaw: 1.2), world: noWindowOnR, input: quiet) == nil)   // face turned away: off-screen
    #expect(e.decide(sample(0.35, yaw: 0.3), world: noWindowOnR, input: quiet) == nil)  // dwell restarted
    #expect(e.decide(sample(0.7, yaw: 0.3), world: noWindowOnR, input: quiet) == .display("R"))
}

@Test func nanRawGazeNeverPoisonsClickLearning() {
    let e = engine()
    _ = e.decide(sample(0, yaw: -0.3, raw: CGPoint(x: 0.1, y: 0.5)), world: world, input: quiet)
    // A frame with a non-finite raw point (bad face track) must be treated like a lost face:
    // not appended to the learning history, not just silently dropped inside `learn`.
    _ = e.decide(sample(0.1, yaw: -0.3, raw: CGPoint(x: .nan, y: 0.9)), world: world, input: quiet)
    _ = e.decide(sample(0.2, yaw: -0.3, raw: CGPoint(x: 0.3, y: 0.5)), world: world, input: quiet)
    // Only 2 finite samples remain in history (< 3): recordClick must say so, not report success
    // with a NaN- or misorder-derived point.
    #expect(!e.recordClick(at: CGPoint(x: 300, y: 400), time: 0.25, world: world))
    #expect(e.calibrations["L"]?.learnedPoints.isEmpty == true)
}

@Test func gazeSlightlyPastDisplayEdgeNeverFocusesNeighborWindow() {
    // issue #6: a raw point just past [0,1] (identity map returns it unchanged) must stay
    // clamped to the chosen display, never resolve to a window on the neighboring screen.
    let e = engine()
    let raw = CGPoint(x: 1.01, y: 0.5)   // unclamped global would be (1010, 400): inside window 3 (on R)
    for t in [0.0, 0.35] {
        #expect(e.decide(sample(t, yaw: -0.3, raw: raw), world: world, input: quiet) != .window(3))
    }
}

@Test func clickLearnsMedianOfFiniteSamplesOnly() throws {
    let e = engine()
    _ = e.decide(sample(0, yaw: -0.3, raw: CGPoint(x: 0.1, y: 0.5)), world: world, input: quiet)
    _ = e.decide(sample(0.05, yaw: -0.3, raw: CGPoint(x: .nan, y: 0.5)), world: world, input: quiet)
    _ = e.decide(sample(0.1, yaw: -0.3, raw: CGPoint(x: 0.2, y: 0.5)), world: world, input: quiet)
    _ = e.decide(sample(0.15, yaw: -0.3, raw: CGPoint(x: 0.3, y: 0.5)), world: world, input: quiet)
    #expect(e.recordClick(at: CGPoint(x: 300, y: 400), time: 0.2, world: world))
    let learned = try #require(e.calibrations["L"]?.learnedPoints)
    #expect(learned == [CalibrationPoint(input: CGPoint(x: 0.2, y: 0.5), target: CGPoint(x: 0.3, y: 0.5))])
}

@Test func smoothedEngineStillSwitchesWithinHalfASecond() throws {
    let e = FocusEngine(calibrations: ["L": identity(yaw: -0.3), "R": identity(yaw: 0.3)], settings: FocusSettings())
    #expect(e.smoother != nil)
    let noWindowOnR = World(displays: [L, R], windows: Array(windows.prefix(2)), focusedWindowID: 1)
    for i in 0..<15 { _ = e.decide(sample(Double(i) / 15, yaw: -0.3), world: noWindowOnR, input: quiet) }
    var fired: Double?
    for i in 15..<30 where fired == nil {
        let t = Double(i) / 15
        if e.decide(sample(t, yaw: 0.3), world: noWindowOnR, input: quiet) == .display("R") { fired = t - 1 }
    }
    #expect(try #require(fired) <= 0.5)
}

@Test func sameScreenFocusWaitsTheTypingPause() throws {
    let e = engine()
    var first: Double?
    for i in 0..<40 where first == nil {
        let t = Double(i) / 10
        if e.decide(sample(t, yaw: -0.3, raw: CGPoint(x: 0.75, y: 0.5)), world: world,
                    input: InputActivity(lastKey: 0)) == .window(2) { first = t }
    }
    #expect((3.3...3.45).contains(try #require(first)))
}

@Test func learnFromClicksOffNeverLearns() {
    let e = engine()
    e.settings.learnFromClicks = false
    for t in [0, 0.1, 0.2] { _ = e.decide(sample(t, yaw: -0.3, raw: CGPoint(x: 0.2, y: 0.2)), world: world, input: quiet) }
    #expect(!e.recordClick(at: CGPoint(x: 300, y: 200), time: 0.25, world: world))
    #expect(e.calibrations["L"]?.learnedPoints.isEmpty == true)
}

@Test func recalibratingADisplayClearsWhatWasLearned() {
    let e = engine()
    for t in [0, 0.1, 0.2] { _ = e.decide(sample(t, yaw: -0.3, raw: CGPoint(x: 0.2, y: 0.2)), world: world, input: quiet) }
    #expect(e.recordClick(at: CGPoint(x: 300, y: 200), time: 0.25, world: world))
    var fresh = identity(yaw: -0.3)
    fresh.learnedPoints = [CalibrationPoint(input: .zero, target: .zero)]   // even if the caller forgot
    e.setCalibration(fresh, for: "L")
    #expect(e.calibrations["L"]?.learnedPoints.isEmpty == true)
    #expect(e.calibrations["R"] != nil)
}

@Test func settingsChangesReachTheClassifier() {
    let e = engine()
    e.settings.headTurn = 0.7
    _ = e.decide(sample(0, yaw: -0.3), world: world, input: quiet)
    for i in 1...6 { #expect(e.decide(sample(Double(i) / 10, yaw: 0.1), world: world, input: quiet) == nil) }
    e.settings.headTurn = 0.5                     // 0.1 rad = 0.67 of the gap: now past the boundary
    var acted = false
    for i in 7...12 { acted = acted || e.decide(sample(Double(i) / 10, yaw: 0.1), world: world, input: quiet) != nil }
    #expect(acted)
}

@Test func screenSwitchFocusesTheWindowLookedAt() {
    let e = engine()
    for t in [0, 0.1, 0.2] { #expect(e.decide(sample(t, yaw: 0.3), world: world, input: quiet) == nil) }
    #expect(e.decide(sample(0.35, yaw: 0.3), world: world, input: quiet) == .window(3))
}

@Test func latchStopsRepeatingNoEffectAction() {
    let e = engine()
    var actions: [FocusAction] = []
    for i in 0..<30 {
        if let a = e.decide(sample(Double(i) / 10, yaw: 0.3), world: noWindowOnR, input: quiet) { actions.append(a) }
    }
    #expect(actions == [.display("R")])                     // focus never moved: fired once, not every 300 ms
    for i in 30..<33 { _ = e.decide(sample(Double(i) / 10, yaw: 1.2), world: noWindowOnR, input: quiet) }
    for i in 33..<40 {
        if let a = e.decide(sample(Double(i) / 10, yaw: 0.3), world: noWindowOnR, input: quiet) { actions.append(a) }
    }
    #expect(actions == [.display("R"), .display("R")])      // a new glance may try again
}

@Test func latchReleasesWhenFocusMoves() {
    var l = ActionLatch()
    #expect(l.admit(.window(2), candidate: .window(2), focused: 1) == .window(2))
    #expect(l.admit(.window(2), candidate: .window(2), focused: 1) == nil)
    #expect(l.admit(.window(2), candidate: .window(2), focused: 3) == .window(2))
}

@Test func latchReleasesWhenTheCandidateChanges() {
    var l = ActionLatch()
    _ = l.admit(.window(2), candidate: .window(2), focused: 1)
    _ = l.admit(nil, candidate: .window(3), focused: 1)
    #expect(l.admit(.window(2), candidate: .window(2), focused: 1) == .window(2))
}

@Test func statusFollowsWhatTheEngineSees() {
    let e = engine()
    _ = e.decide(sample(0, yaw: -0.3), world: world, input: quiet)
    #expect(e.status == .facing("L"))
    _ = e.decide(.noFace(at: 0.1), world: world, input: quiet)
    #expect(e.status == .noFace)
    _ = e.decide(sample(0.2, yaw: 1.2), world: world, input: quiet)
    #expect(e.status == .lookingAway)
}

@Test func statusNeedsCalibrationWhenNoConnectedDisplayIsCalibrated() {
    let e = FocusEngine(calibrations: [:], settings: FocusSettings())
    _ = e.decide(sample(0, yaw: 0), world: world, input: quiet)
    #expect(e.status == .needsCalibration)
}

@Test func statusAsksForWindowFocusOnASingleDisplay() {
    let e = engine()
    e.settings.windowFocus = false
    _ = e.decide(sample(0, yaw: -0.3), world: World(displays: [L], windows: windows, focusedWindowID: 1), input: quiet)
    #expect(e.status == .oneDisplayWindowFocusOff)
}

@Test func gazePointAndPoseArePublished() {
    let e = engine()
    _ = e.decide(sample(0, yaw: -0.3, raw: CGPoint(x: 0.25, y: 0.5)), world: world, input: quiet)
    #expect(e.lastGazePoint == CGPoint(x: 250, y: 400))
    #expect(e.lastPose?.yaw == -0.3)
}

@Test func idlePathClearsTheGazePointAndPose() {
    let e = engine()
    _ = e.decide(sample(0, yaw: -0.3, raw: CGPoint(x: 0.25, y: 0.5)), world: world, input: quiet)
    #expect(e.lastGazePoint != nil)
    _ = e.decide(.noFace(at: 1), world: world, input: quiet)
    #expect(e.lastGazePoint == nil)
    #expect(e.lastPose == nil)
}
