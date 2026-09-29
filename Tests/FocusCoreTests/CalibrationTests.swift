import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private let targets = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.9),
                       CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.5, y: 0.5)]

private func samples(at p: CGPoint, yaw: Double, count: Int = 10) -> [GazeSample] {
    var out = (0..<count).map { i in
        GazeSample(time: Double(i), raw: p, pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), confidence: 1)
    }
    // A low-confidence outlier that must be ignored.
    out.append(GazeSample(time: 99, raw: CGPoint(x: 9, y: 9), pose: PoseFeature(yaw: 3, pitch: 3, faceX: 0, faceY: 0), confidence: 0))
    return out
}

@Test func medianOfOddAndEven() {
    #expect(median([3, 1, 2]) == 2)
    #expect(median([4, 1, 2, 3]) == 2.5)
}

@Test func buildsFivePointsAndMedianPose() throws {
    let cal = try #require(CalibrationBuilder.build(
        targets: targets.map { ($0, samples(at: $0, yaw: 0.3)) }, minConfidence: 0.5))
    #expect(cal.calibrationPoints.count == 5)
    #expect(cal.calibrationPoints.allSatisfy { $0.input == $0.target })
    #expect(cal.pose.yaw == 0.3)
    #expect(cal.map != nil)
}

@Test func skipsTargetsWithTooFewSamplesAndFailsBelowThree() {
    let sparse = targets.map { ($0, samples(at: $0, yaw: 0, count: 2)) }
    #expect(CalibrationBuilder.build(targets: sparse, minConfidence: 0.5) == nil)
}

@Test func learnedPointsAreCapped() throws {
    var cal = try #require(CalibrationBuilder.build(
        targets: targets.map { ($0, samples(at: $0, yaw: 0)) }, minConfidence: 0.5))
    for i in 0..<205 {
        let p = CGPoint(x: Double(i % 10) / 10, y: 0.5)
        cal.learn(CalibrationPoint(input: p, target: p))
    }
    #expect(cal.learnedPoints.count == DisplayCalibration.maxLearned)
    #expect(cal.recentErrors.count == DisplayCalibration.errorWindow)
}

@Test func recalibrationFlagNeedsTenBadClicks() throws {
    var cal = try #require(CalibrationBuilder.build(
        targets: targets.map { ($0, samples(at: $0, yaw: 0)) }, minConfidence: 0.5))
    cal.recentErrors = Array(repeating: 0.5, count: 9)
    #expect(!cal.needsRecalibration)
    cal.recentErrors.append(0.5)
    #expect(cal.needsRecalibration)
    cal.recentErrors = Array(repeating: 0.01, count: 30)
    #expect(!cal.needsRecalibration)
}

// Issue #4: a single non-finite point must not silently disable the RBF map.
@Test func learnIgnoresNonFinitePoint() throws {
    var cal = try #require(CalibrationBuilder.build(
        targets: targets.map { ($0, samples(at: $0, yaw: 0)) }, minConfidence: 0.5))
    let learnedBefore = cal.learnedPoints.count
    cal.learn(CalibrationPoint(input: CGPoint(x: .nan, y: 0.5), target: CGPoint(x: 0.5, y: 0.5)))
    #expect(cal.map != nil)
    #expect(cal.learnedPoints.count == learnedBefore)
    #expect(throws: Never.self) { try JSONEncoder().encode(cal) }
}

@Test func buildIgnoresNonFiniteSamples() throws {
    // The first target's confident samples are all non-finite; if `build` doesn't filter
    // them out, `median` returns NaN and the resulting calibration point poisons the map.
    var nanSamples = targets.map { ($0, samples(at: $0, yaw: 0)) }
    nanSamples[0] = (targets[0], samples(at: CGPoint(x: Double.nan, y: Double.nan), yaw: 0))
    let cal = try #require(CalibrationBuilder.build(targets: nanSamples, minConfidence: 0.5))
    #expect(cal.map != nil)
}

@Test func buildIgnoresNonFinitePoseInMedian() throws {
    // Half of each target's confident, finite-raw samples have a NaN yaw. If `build` doesn't
    // also filter on pose finiteness, `median` mixes NaN into the pose computation and
    // `sorted()` over NaN is unordered, so the resulting pose is not reliably finite.
    var withNaNYaw = targets.map { ($0, samples(at: $0, yaw: 0.3)) }
    for i in withNaNYaw.indices {
        for j in withNaNYaw[i].1.indices where j % 2 == 0 {
            withNaNYaw[i].1[j].pose.yaw = Double.nan
        }
    }
    let cal = try #require(CalibrationBuilder.build(targets: withNaNYaw, minConfidence: 0.5))
    #expect(cal.pose.yaw.isFinite)
    #expect(cal.pose.yaw == 0.3)
    #expect(cal.pose.pitch == 0)
    #expect(cal.pose.faceX == 0.5)
    #expect(cal.pose.faceY == 0.5)
}
