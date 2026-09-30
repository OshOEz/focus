import Foundation
import Testing
@testable import FocusCore

private func pose(_ yaw: Double) -> PoseFeature { PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5) }

private func classifier(headTurn: Double = 0.5) -> ScreenClassifier {
    ScreenClassifier(centroids: ["L": pose(-0.3), "R": pose(0.3)], headTurn: headTurn, maxDistance: 0.35)
}

@Test func picksNearestScreen() {
    var c = classifier()
    #expect(c.classify(pose(-0.25)) == "L")
    #expect(c.classify(pose(0.28)) == "R")
}

@Test func boundaryKeepsCurrentNearTheMiddle() {
    var c = classifier()
    #expect(c.classify(pose(-0.3)) == "L")
    // Slightly right of the midpoint: R is nearer, but not by 25 %.
    #expect(c.classify(pose(0.02)) == "L")
    #expect(c.classify(pose(0.2)) == "R")
}

@Test func farFromEveryScreenIsOffScreen() {
    var c = classifier()
    #expect(c.classify(pose(1.2)) == nil)
}

@Test func noCentroidsMeansNothing() {
    var c = ScreenClassifier(centroids: [:], maxDistance: 0.35)
    #expect(c.classify(pose(0)) == nil)
}

@Test func removedCurrentScreenSwitchesToBest() {
    var c = classifier()
    #expect(c.classify(pose(-0.3)) == "L")
    c.centroids["L"] = nil   // display unplugged / calibration dropped
    #expect(c.classify(pose(0.1)) == "R")
}

@Test func poseMedianIgnoresNonFinitePoses() throws {
    let poses = [pose(0.1), pose(0.3), PoseFeature(yaw: .nan, pitch: 0, faceX: 0.5, faceY: 0.5), pose(0.2)]
    let m = try #require(PoseFeature.median(of: poses))
    #expect(m.yaw == 0.2 && m.pitch == 0 && m.faceX == 0.5)
}

@Test func poseMedianOfNothingUsableIsNil() {
    #expect(PoseFeature.median(of: []) == nil)
    #expect(PoseFeature.median(of: [PoseFeature(yaw: .infinity, pitch: 0, faceX: 0, faceY: 0)]) == nil)
}

@Test func higherHeadTurnNeedsABiggerTurn() {
    var normal = classifier(headTurn: 0.5), strict = classifier(headTurn: 0.7)
    _ = normal.classify(pose(-0.3)); _ = strict.classify(pose(-0.3))
    #expect(normal.classify(pose(0.1)) == "R")   // 0.67 of the gap > 0.60
    #expect(strict.classify(pose(0.1)) == "L")   // 0.67 < 0.70
}

@Test func lowHeadTurnNeverPingPongs() {
    var c = classifier(headTurn: 0.3)            // threshold 0.5: the midpoint
    _ = c.classify(pose(-0.3))
    var flips = 0, last = "L"
    for i in 0..<200 {
        let yaw = (i % 2 == 0 ? 0.02 : -0.02) * Double(i % 7) / 6   // jitter around the bezel
        let k = c.classify(pose(yaw))!
        if k != last { flips += 1; last = k }
    }
    #expect(flips <= 1)
}

@Test func returnBandMakesGoingBackHarder() {
    var c = classifier(headTurn: 0.5)
    _ = c.classify(pose(-0.3))
    #expect(c.classify(pose(0.1)) == "R")        // L → R at 0.67 of the gap
    #expect(c.classify(pose(-0.05)) == "R")      // back toward L: 0.58 < 0.60 + 0.05
    #expect(c.classify(pose(-0.1)) == "L")       // 0.67 > 0.65
}

@Test func cloudsMoveTheBoundaryToTheFacingEdges() {
    let clouds = ["L": [pose(-0.4), pose(-0.3), pose(-0.2)], "R": [pose(0.2), pose(0.3), pose(0.4)]]
    var withClouds = ScreenClassifier(centroids: ["L": pose(-0.3), "R": pose(0.3)], clouds: clouds, maxDistance: 0.35)
    var centroidsOnly = classifier()
    _ = withClouds.classify(pose(-0.3)); _ = centroidsOnly.classify(pose(-0.3))
    // 0.05 rad: 0.625 of the gap between the facing dots (−0.2…0.2), 0.58 between centroids.
    #expect(withClouds.classify(pose(0.05)) == "R")
    #expect(centroidsOnly.classify(pose(0.05)) == "L")
}

@Test func threeScreensPicksTheNearestScreenPastItsBoundary() {
    var c = ScreenClassifier(centroids: ["L": pose(-0.6), "M": pose(0), "R": pose(0.6)], maxDistance: 0.35)
    _ = c.classify(pose(-0.6))
    #expect(c.classify(pose(0.6)) == "R")        // past M's boundary too, but R is nearer
}

@Test func headTurnIsClampedToItsRange() {
    #expect(classifier(headTurn: 0).threshold == 0.5)
    #expect(abs(classifier(headTurn: 1).threshold - 0.7) < 1e-12)
}

// Issue #17: facing-edge dots 0.001 rad apart (calibration-dot noise, not a real gap) must not
// turn a tiny denominator into a hair-trigger switch. Below the pose-jitter floor, gapFraction
// falls back to centroid-to-centroid geometry, same as a display with no dots at all.
@Test func tinyCloudGapFallsBackAndNeverPingPongs() {
    let clouds = ["L": [pose(-0.3), pose(-0.0005)], "R": [pose(0.0005), pose(0.3)]]
    for tenthsOfHeadTurn in stride(from: 3, through: 7, by: 1) {
        let headTurn = Double(tenthsOfHeadTurn) / 10
        var c = ScreenClassifier(centroids: ["L": pose(-0.3), "R": pose(0.3)], clouds: clouds,
                                  headTurn: headTurn, maxDistance: 0.35)
        _ = c.classify(pose(-0.3))
        var flips = 0, last = "L"
        for i in 0..<200 {
            let yaw = -0.0005 + (i % 2 == 0 ? 0.005 : -0.005) * Double(i % 7) / 6   // jitter around L's edge dot
            let k = c.classify(pose(yaw))!
            if k != last { flips += 1; last = k }
        }
        #expect(flips <= 1, "headTurn \(headTurn): \(flips) flips")
    }
}

/// Bench `bezel/side-by-side`: edge dots 3 % inside two 1920-pt screens put the facing edges at
/// ±0.021 rad yaw (head 1800 pt away), ±0.029 at 1300 pt; staring at the seam with rest pose noise
/// (σ 0.01 rad, through the engine's default GazeSmoother as in use) must not ping-pong at either distance.
@Test(arguments: [0.021, 0.029])
func seamStareWithRestNoiseNeverPingPongs(edge: Double) {
    var state: UInt64 = 42   // SplitMix64 + Box–Muller: seeded so the test is deterministic
    func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    func noise() -> Double { 0.01 * (-2 * log(max(uniform(), .ulpOfOne))).squareRoot() * cos(2 * .pi * uniform()) }
    let clouds = ["L": [pose(-0.3), pose(-edge)], "R": [pose(edge), pose(0.3)]]
    var c = ScreenClassifier(centroids: ["L": pose(-0.15), "R": pose(0.15)], clouds: clouds, maxDistance: 0.35)
    _ = c.classify(pose(-0.15))
    var smoother = GazeSmoother()
    var flips = 0, last = "L"
    for i in 0..<150 {   // 10 s at 15 fps
        let s = smoother.smooth(GazeSample(time: Double(i) / 15, raw: CGPoint(x: 0.5, y: 0.5), pose: pose(noise()), confidence: 1))
        let k = c.classify(s.pose)!
        if k != last { flips += 1; last = k }
    }
    #expect(flips <= 1, "edges ±\(edge): \(flips) flips")
}
