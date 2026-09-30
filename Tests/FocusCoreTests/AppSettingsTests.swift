import Foundation
import Testing
@testable import FocusCore

@Suite struct AppSettingsTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func defaultsMatchDocumentedValues() {
        let s = AppSettings()
        #expect(!s.showGazeDot)
        #expect(s.launchAtLogin && s.moveCursor && !s.onboardingCompleted && !s.loginItemDefaultApplied)
        #expect(s.cameraID == nil)
        #expect(s.hotKey.label == "⇧⌘G")
    }

    @Test func roundTrips() throws {
        var s = AppSettings()
        s.showGazeDot = true
        s.cameraID = "0x1420000005ac8600"
        s.hotKey = HotKeySpec(keyCode: 0, modifiers: HotKeySpec.control | HotKeySpec.option, key: "A")
        s.notifiedDisplays = ["4268-16600-777"]
        s.engine.typingPause = 5
        let store = SettingsStore(url: tempURL())
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test func missingAndMistypedKeysKeepDefaults() throws {
        let url = tempURL()
        try write(#"{"launchAtLogin": "no", "moveCursor": false, "keyFromTheFuture": 1}"#, to: url)
        let s = SettingsStore(url: url).load()
        #expect(s.launchAtLogin == true)      // mistyped → default
        #expect(s.moveCursor == false)        // valid → kept
        #expect(s.hotKey == .default)         // missing → default
        #expect(s.engine == FocusSettings())
    }

    @Test func garbageIsSetAsideAsBroken() throws {
        let url = tempURL()
        try write("not json", to: url)
        #expect(SettingsStore(url: url).load() == AppSettings())
        #expect(FileManager.default.fileExists(atPath: url.path + ".broken"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func missingFileGivesDefaults() {
        #expect(SettingsStore(url: tempURL()).load() == AppSettings())
    }

    @Test func hotKeyNeedsARealModifier() {
        #expect(!HotKeySpec(keyCode: 5, modifiers: HotKeySpec.shift, key: "G").isValid)
        #expect(!HotKeySpec(keyCode: 5, modifiers: 0, key: "G").isValid)
        #expect(HotKeySpec(keyCode: 5, modifiers: HotKeySpec.option, key: "G").isValid)
        #expect(HotKeySpec.default.isValid)
    }

    @Test func labelUsesAppleModifierOrder() {
        let all = HotKeySpec.command | HotKeySpec.shift | HotKeySpec.option | HotKeySpec.control
        #expect(HotKeySpec(keyCode: 40, modifiers: all, key: "K").label == "⌃⌥⇧⌘K")
    }
}
