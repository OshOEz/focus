import Testing
@testable import FocusCore

private func pose(_ yaw: Double) -> PoseFeature { PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5) }

private func classifier() -> ScreenClassifier {
    ScreenClassifier(centroids: ["L": pose(-0.3), "R": pose(0.3)], hysteresis: 0.25, maxDistance: 0.35)
}

@Test func picksNearestScreen() {
    var c = classifier()
    #expect(c.classify(pose(-0.25)) == "L")
    #expect(c.classify(pose(0.28)) == "R")
}

@Test func hysteresisKeepsCurrentNearTheMiddle() {
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
    var c = ScreenClassifier(centroids: [:], hysteresis: 0.25, maxDistance: 0.35)
    #expect(c.classify(pose(0)) == nil)
}

@Test func removedCurrentScreenSwitchesToBest() {
    var c = classifier()
    #expect(c.classify(pose(-0.3)) == "L")
    c.centroids["L"] = nil   // display unplugged / calibration dropped
    #expect(c.classify(pose(0.1)) == "R")
}
