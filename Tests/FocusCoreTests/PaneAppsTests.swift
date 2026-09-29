import Testing
@testable import FocusCore

@Test func allowsKnownTerminalsAndEditors() {
    #expect(PaneApps.isAllowed("com.googlecode.iterm2"))
    #expect(PaneApps.isAllowed("com.microsoft.VSCode"))
}

@Test func allowsAnyJetBrainsIDE() {
    #expect(PaneApps.isAllowed("com.jetbrains.intellij"))
    #expect(PaneApps.isAllowed("com.jetbrains.pycharm"))
}

@Test func rejectsOtherApps() {
    #expect(!PaneApps.isAllowed("com.apple.Safari"))
    #expect(!PaneApps.isAllowed(""))
}
