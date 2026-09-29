import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1),
                       CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)]

private func near(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 0.02) -> Bool {
    abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
}

@Test func solvesSmallSystem() throws {
    // 2x + y = 5 ; x + 3y = 10  →  x = 1, y = 3
    let x = try #require(solveLinear([2, 1, 1, 3], [5, 10], n: 2, m: 1))
    #expect(abs(x[0] - 1) < 1e-9 && abs(x[1] - 3) < 1e-9)
}

@Test func singularSystemReturnsNil() {
    #expect(solveLinear([1, 2, 2, 4], [1, 2], n: 2, m: 1) == nil)
}

@Test func learnsConstantOffsetAtCalibrationPoints() throws {
    let pts = corners.map { CalibrationPoint(input: $0, target: CGPoint(x: $0.x + 0.1, y: $0.y - 0.05)) }
    let map = try #require(RBFMap(points: pts))
    for p in pts { #expect(near(map.map(p.input), p.target)) }
}

@Test func farFromDataFallsBackToIdentity() throws {
    let pts = corners.map { CalibrationPoint(input: $0, target: CGPoint(x: $0.x + 0.1, y: $0.y)) }
    let map = try #require(RBFMap(points: pts))
    #expect(near(map.map(CGPoint(x: 50, y: 50)), CGPoint(x: 50, y: 50), 1e-6))
}

@Test func needsThreePoints() {
    let pts = corners.prefix(2).map { CalibrationPoint(input: $0, target: $0) }
    #expect(RBFMap(points: Array(pts)) == nil)
}

@Test func duplicateInputsStayFinite() throws {
    let pts = Array(repeating: CalibrationPoint(input: CGPoint(x: 0.5, y: 0.5), target: CGPoint(x: 0.6, y: 0.5)), count: 5)
    let map = try #require(RBFMap(points: pts))
    let out = map.map(CGPoint(x: 0.5, y: 0.5))
    #expect(out.x.isFinite && out.y.isFinite)
}

@Test func calibrationPointRoundTripsThroughCodable() throws {
    let original = CalibrationPoint(input: CGPoint(x: 0.1, y: 0.2), target: CGPoint(x: 0.3, y: 0.4))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CalibrationPoint.self, from: data)
    #expect(decoded == original)
}
