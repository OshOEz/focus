import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private let fps = 15.0

@Test func oneEuroFirstValuePassesThrough() {
    var f = OneEuroFilter(minCutoff: 1, beta: 1.5)
    #expect(f.filter(0.42, at: 10) == 0.42)
}

@Test func oneEuroConstantStaysConstant() {
    var f = OneEuroFilter(minCutoff: 1, beta: 1.5)
    for i in 0..<30 { #expect(abs(f.filter(0.3, at: Double(i) / fps) - 0.3) < 1e-12) }
}

@Test func oneEuroDampsJitterAtRest() {
    var f = OneEuroFilter(minCutoff: 1, beta: 1.5)
    var out: [Double] = []
    for i in 0..<30 { out.append(f.filter(0.3 + (i % 2 == 0 ? 0.02 : -0.02), at: Double(i) / fps)) }
    let tail = out.suffix(10)
    #expect(tail.max()! - tail.min()! < 0.02)   // input swings 0.04 peak to peak
}

@Test func oneEuroFollowsAStepQuickly() {
    var f = OneEuroFilter(minCutoff: 1, beta: 1.5)
    for i in 0..<15 { _ = f.filter(0, at: Double(i) / fps) }
    var y = 0.0
    for i in 15..<20 { y = f.filter(0.6, at: Double(i) / fps) }   // 5 frames = 0.27 s after the step
    #expect(y > 0.54)
}

@Test func oneEuroIgnoresZeroOrNegativeTimeStep() {
    var f = OneEuroFilter(minCutoff: 1, beta: 1.5)
    _ = f.filter(0.1, at: 1)
    #expect(f.filter(0.9, at: 1) == 0.1)
    #expect(f.filter(0.9, at: 0.5) == 0.1)
}

private func s(_ t: Double, yaw: Double) -> GazeSample {
    GazeSample(time: t, raw: CGPoint(x: 0.5, y: 0.5), pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), confidence: 1)
}

@Test func smootherResetsOnNoFace() {
    var g = GazeSmoother()
    for i in 0..<15 { _ = g.smooth(s(Double(i) / fps, yaw: 0.3)) }
    let lost = g.smooth(.noFace(at: 1.0))
    #expect(!lost.hasFace && lost.confidence == 0)
    // The next face starts fresh instead of being dragged toward the old pose.
    #expect(g.smooth(s(1.07, yaw: -0.3)).pose.yaw == -0.3)
}

@Test func smootherResetsAfterAGap() {
    var g = GazeSmoother()
    _ = g.smooth(s(0, yaw: 0.3))
    #expect(g.smooth(s(GazeSmoother.maxGap + 0.1, yaw: -0.3)).pose.yaw == -0.3)
}

@Test func nanPoseNeverPoisonsTheSmoother() {
    var g = GazeSmoother()
    _ = g.smooth(s(0, yaw: 0.3))
    var bad = s(0.07, yaw: .nan)
    bad.raw = CGPoint(x: 0.5, y: 0.5)
    _ = g.smooth(bad)
    #expect(g.smooth(s(0.13, yaw: 0.2)).pose.yaw.isFinite)
}
