import Foundation
import Testing
@testable import FocusCore

private let builtIn = DisplayFingerprint(vendor: 1552, model: 41_000, serial: 1, width: 1512, height: 982, originX: 0, originY: 0)
private let dell = DisplayFingerprint(vendor: 4268, model: 16_600, serial: 777, width: 2560, height: 1440, originX: 1512, originY: 0)

@Test func newDisplayIsAnnouncedOncePerDisplay() {
    #expect(NotificationPolicy.newDisplays(present: ["A", "B", "C"], calibrated: ["A"], notified: ["C"]) == ["B"])
}

@Test func driftIsAnnouncedOncePerCalibration() {
    let pose = PoseFeature(yaw: 0, pitch: 0, faceX: 0.5, faceY: 0.5)
    let bad = DisplayCalibration(pose: pose, calibrationPoints: [], recentErrors: Array(repeating: 0.5, count: 10))
    let good = DisplayCalibration(pose: pose, calibrationPoints: [])
    #expect(NotificationPolicy.drifted(["A": bad, "B": good, "C": bad], notified: ["C"]) == ["A"])
}

@Test func layoutChangedOnlyWhenTheSameScreensMoved() {
    var movedDell = dell
    movedDell.originX = -2560
    #expect(NotificationPolicy.layoutChanged(from: [builtIn, dell], to: [builtIn, movedDell]))
    #expect(!NotificationPolicy.layoutChanged(from: [builtIn, dell], to: [dell, builtIn]))
    #expect(!NotificationPolicy.layoutChanged(from: [builtIn], to: [builtIn, dell]))   // that's "new display"
}
