import Foundation
import Testing
@testable import FocusCore

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "json"))
}

@Test func settingsDecodeToleratesAPlanOneFile() throws {
    let s = try JSONDecoder().decode(FocusSettings.self, from: Data(contentsOf: fixture("settings-v1")))
    #expect(s.screenDwell == 0.5 && s.typingPause == 4 && !s.windowFocus)   // kept
    #expect(s.headTurn == 0.5 && s.learnFromClicks && s.waitWhileTyping)   // new keys: defaults
}

@Test func emptySettingsObjectDecodesToDefaults() throws {
    #expect(try JSONDecoder().decode(FocusSettings.self, from: Data("{}".utf8)) == FocusSettings())
}

@Test func settingsRoundTrip() throws {
    var s = FocusSettings()
    s.headTurn = 0.65; s.learnFromClicks = false; s.syntheticClickFallback = false; s.waitWhileTyping = false
    #expect(try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(s)) == s)
}

@Test func planOneSetupFixtureDecodes() throws {
    let setup = try JSONDecoder().decode(Setup.self, from: Data(contentsOf: fixture("setup-v1")))
    let cal = try #require(setup.calibrations["1552-41000-1"])
    #expect(cal.calibrationPoints.count == 5 && cal.dotPoses.isEmpty && cal.map != nil)
    #expect(setup.fingerprint.wifiSSID == nil)
}

@Test func storeLoadsThePlanOneSetupWithoutQuarantine() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture("setup-v1"),
                                     to: dir.appendingPathComponent("6F9619FF-8B86-D011-B42D-00C04FC964FF.json"))
    #expect(SetupStore(directory: dir).loadAll().count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".broken") })
}
