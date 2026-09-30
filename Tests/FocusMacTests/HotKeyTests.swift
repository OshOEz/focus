import AppKit
import Carbon
import Testing
import FocusCore
@testable import FocusMac

@Test func hotKeyNeedsCommandControlOrOption() {
    #expect(HotKey.isValid(modifiers: UInt32(cmdKey | shiftKey)))
    #expect(HotKey.isValid(modifiers: UInt32(optionKey)))
    #expect(!HotKey.isValid(modifiers: UInt32(shiftKey)))   // ⇧ alone would fire while typing capitals
    #expect(!HotKey.isValid(modifiers: 0))
}

@Test func carbonModifiersFromEventFlags() {
    #expect(HotKey.carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
    #expect(HotKey.carbonModifiers([.control, .option, .capsLock]) == UInt32(controlKey | optionKey))
    // R1 (reconciliation): the hot key lives on AppSettings.hotKey (HotKeySpec), not on FocusSettings.
    #expect(AppSettings().hotKey.modifiers == UInt32(cmdKey | shiftKey))   // ⇧⌘G by default
    #expect(AppSettings().hotKey.keyCode == UInt32(kVK_ANSI_G))
}

@Test func invalidHotKeyIsRefusedBeforeRegistering() {
    #expect(HotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(shiftKey)) {} == nil)
}

@MainActor @Test func permissionStatusesAreReadWithoutPrompting() {
    // The check is that reading them never prompts or hangs.
    _ = (Permissions.camera, Permissions.accessibility, Permissions.location, Permissions.eventPosting)
}
