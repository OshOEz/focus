import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private func d(_ key: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> DisplayInfo {
    DisplayInfo(key: key, frame: CGRect(x: x, y: y, width: w, height: h))
}

@Test func singleDisplayGetsTheNineDotGrid() throws {
    let a = try #require(CalibrationLayout.targets(for: [d("A", 0, 0, 1512, 982)])["A"])
    #expect(a.count == 9)
    #expect(a.first == CGPoint(x: 0.1, y: 0.12) && a.last == CGPoint(x: 0.9, y: 0.88))
}

@Test func sideBySideScreensGetDotsOnTheSharedEdge() throws {
    let t = CalibrationLayout.targets(for: [d("L", 0, 0, 1000, 800), d("R", 1000, 0, 1000, 800)])
    let l = try #require(t["L"]), r = try #require(t["R"])
    #expect(l.count == 12 && r.count == 12)
    #expect(l.suffix(3).allSatisfy { $0.x == 0.97 } && r.suffix(3).allSatisfy { $0.x == 0.03 })
    #expect(l.suffix(3).map(\.y) == [0.25, 0.5, 0.75])
}

@Test func laptopBelowTwoMonitorsGetsDotsOnEverySharedEdge() {
    let t = CalibrationLayout.targets(for: [d("A", 0, 0, 2560, 1440), d("B", 2560, 0, 2560, 1440),
                                            d("M", 1792, 1440, 1536, 960)])
    #expect(t["M"]?.count == 15)   // 9 + 3 under A + 3 under B
    #expect(t["A"]?.count == 15)   // 9 + 3 facing B + 3 above M
    #expect(t.values.joined().allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
}

@Test func screensThatLookTheSameAreReported() {
    func cal(_ yaw: Double) -> DisplayCalibration {
        DisplayCalibration(pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), calibrationPoints: [])
    }
    #expect(CalibrationBuilder.indistinguishable(["A": cal(0), "B": cal(0.03), "C": cal(0.4)]) == ["A", "B"])
    #expect(CalibrationBuilder.indistinguishable(["A": cal(0), "C": cal(0.4)]).isEmpty)
}
