import Foundation
import Testing
@testable import FocusCore

private let builtIn = DisplayFingerprint(vendor: 1552, model: 41_000, serial: 1, width: 3024, height: 1964, originX: 0, originY: 0)
private let dell = DisplayFingerprint(vendor: 4268, model: 16_600, serial: 777, width: 2560, height: 1440, originX: 3024, originY: 0)

private func setup(_ name: String, _ displays: [DisplayFingerprint], ssid: String? = nil) -> Setup {
    Setup(id: UUID(), name: name, fingerprint: Fingerprint(displays: displays, cameraID: "cam", wifiSSID: ssid), calibrations: [:])
}

@Test func identicalMonitorsWithoutSerialGetDistinctKeys() {
    let a = DisplayFingerprint(vendor: 1, model: 2, serial: 0, width: 1920, height: 1080, originX: 0, originY: 0)
    let b = DisplayFingerprint(vendor: 1, model: 2, serial: 0, width: 1920, height: 1080, originX: 1920, originY: 0)
    #expect(a.key != b.key)
    #expect(dell.key == "4268-16600-777")
}

@Test func matchesSingleSetupIgnoringDisplayOrder() {
    let home = setup("Maison", [builtIn, dell])
    let office = setup("Bureau", [builtIn])
    let now = Fingerprint(displays: [dell, builtIn], cameraID: "cam", wifiSSID: nil)
    #expect(SetupMatcher.match(now, in: [home, office]) == .matched(home.id))
}

@Test func differentCameraDoesNotMatch() {
    let home = setup("Maison", [builtIn])
    #expect(SetupMatcher.match(Fingerprint(displays: [builtIn], cameraID: "usb-cam", wifiSSID: nil), in: [home]) == .none)
}

@Test func wifiBreaksTies() {
    let a = setup("Bureau A", [builtIn, dell], ssid: "Office")
    let b = setup("Coworking", [builtIn, dell], ssid: "Cowork")
    let now = Fingerprint(displays: [builtIn, dell], cameraID: "cam", wifiSSID: "Cowork")
    #expect(SetupMatcher.match(now, in: [a, b]) == .matched(b.id))
    let unknown = Fingerprint(displays: [builtIn, dell], cameraID: "cam", wifiSSID: nil)
    #expect(SetupMatcher.match(unknown, in: [a, b]) == .ambiguous([a.id, b.id]))
}

@Test func storeRoundTripsAndQuarantinesBrokenFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SetupStore(directory: dir)
    let home = setup("Maison", [builtIn, dell])
    try store.save(home)
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

    #expect(store.loadAll() == [home])
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files.filter { $0.hasSuffix(".broken") }.count == 1)

    try store.delete(home.id)
    #expect(store.loadAll().isEmpty)
}

@Test func uniqueKeysSplitsDuplicateSerials() {
    let a = DisplayFingerprint(vendor: 1, model: 2, serial: 42, width: 1920, height: 1080, originX: 0, originY: 0)
    var b = a
    b.originX = 1920
    let keys = DisplayFingerprint.uniqueKeys([a, b, dell])
    #expect(Set(keys).count == 3)
    #expect(keys[2] == dell.key)            // unique displays keep their plain, stable key
}
