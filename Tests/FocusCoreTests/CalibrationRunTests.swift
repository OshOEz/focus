import Foundation
import Testing
@testable import FocusCore

@Suite struct CalibrationRunTests {
    private let grid = [0.12, 0.5, 0.88].flatMap { y in [0.1, 0.5, 0.9].map { x in CGPoint(x: x, y: y) } }

    private func run(_ keys: [String], others: [String: PoseFeature] = [:]) -> CalibrationRun {
        CalibrationRun(screens: keys.map { .init(key: $0, targets: grid) }, others: others, minConfidence: 0.5)
    }

    private func pose(_ yaw: Double) -> PoseFeature { PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5) }

    /// Presses Space at `t0` and plays the current screen: junk during each travel (must be ignored),
    /// then `perDot` samples looking exactly at the target during the hold. Returns the end time.
    @discardableResult
    private func play(_ r: inout CalibrationRun, from t0: Double, yaw: Double, face: Bool = true, perDot: Int = 10) -> Double {
        r.pressSpace(at: t0)
        guard case .dot(let i, _, _) = r.phase else { return t0 }
        var t = t0
        for target in r.screens[i].targets {
            r.add(GazeSample(time: t + 0.1, raw: CGPoint(x: 9, y: 9), pose: pose(1.5), confidence: 1))
            for n in 0..<perDot {
                let st = t + CalibrationRun.travel + Double(n) * CalibrationRun.hold / Double(perDot)
                r.add(GazeSample(time: st, raw: face ? target : CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                 pose: face ? pose(yaw) : pose(.nan), confidence: face ? 1 : 0))
            }
            t += CalibrationRun.travel + CalibrationRun.hold
            r.tick(at: t)
        }
        return t
    }

    @Test func twoScreensFinish() {
        var r = run(["L", "R"])
        #expect(r.phase == .ready(screen: 0))
        let t = play(&r, from: 0, yaw: -0.3)
        #expect(r.phase == .ready(screen: 1))
        play(&r, from: t + 2, yaw: 0.3)
        #expect(r.phase == .finished)
        #expect(Set(r.results.keys) == ["L", "R"])
        #expect(r.results["L"]?.calibrationPoints.count == 9)
        #expect(r.results["R"]?.pose.yaw == 0.3)
    }

    @Test func travelAndPreSpaceSamplesIgnored() {
        var r = run(["L"])
        // Captured while the user was still reading the instructions.
        r.add(GazeSample(time: -1, raw: CGPoint(x: 9, y: 9), pose: pose(1.5), confidence: 1))
        play(&r, from: 0, yaw: -0.3)
        let cal = r.results["L"]
        #expect(cal?.calibrationPoints.allSatisfy { $0.input == $0.target } == true)
        #expect(cal?.pose.yaw == -0.3)
    }

    @Test func noFaceFailsAndRetriesSameScreen() {
        var r = run(["L", "R"])
        play(&r, from: 0, yaw: -0.3, face: false)
        #expect(r.phase == .failed(screen: 0, .noFace))
        #expect(r.results.isEmpty)
        r.pressSpace(at: 50)
        #expect(r.phase == .dot(screen: 0, index: 0, start: 50))
    }

    @Test func screensThatLookAlikeRestartTheRun() {
        var r = run(["L", "R"])
        let t = play(&r, from: 0, yaw: 0)
        play(&r, from: t + 1, yaw: 0.01)
        #expect(r.phase == .failed(screen: 1, .screensLookedSame))
        r.pressSpace(at: 100)
        #expect(r.results.isEmpty)
        #expect(r.phase == .dot(screen: 0, index: 0, start: 100))
    }

    @Test func othersCountForSeparation() {
        var r = run(["R"], others: ["L": pose(0)])
        play(&r, from: 0, yaw: 0.02)
        #expect(r.phase == .failed(screen: 0, .screensLookedSame))
        var ok = run(["R"], others: ["L": pose(-0.3)])
        play(&ok, from: 0, yaw: 0.3)
        #expect(ok.phase == .finished)
    }

    @Test func escapeCancelsAndDiscards() {
        var r = run(["L", "R"])
        play(&r, from: 0, yaw: -0.3)
        r.pressEscape()
        #expect(r.phase == .cancelled)
        #expect(r.results.isEmpty)
    }

    @Test func dotTravelsThenHolds() {
        var r = run(["L"])
        r.pressSpace(at: 0)
        r.pressSpace(at: 0.3)   // ignored mid-dot
        #expect(r.phase == .dot(screen: 0, index: 0, start: 0))
        #expect(r.dot(at: 0)?.point == grid[0])
        #expect(abs((r.dot(at: CalibrationRun.travel + 0.5)?.progress ?? 0) - 0.5) < 1e-9)
        r.tick(at: CalibrationRun.travel + CalibrationRun.hold)
        let mid = r.dot(at: CalibrationRun.travel + CalibrationRun.hold + CalibrationRun.travel / 2)!.point
        #expect(mid.x > grid[0].x && mid.x < grid[1].x)   // on its way to dot 2
    }
}
