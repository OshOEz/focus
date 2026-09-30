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

@Test func allowsEveryListedAppPlusXirp() {
    #expect(PaneApps.isAllowed("com.microsoft.VSCodeInsiders"))
    #expect(PaneApps.isAllowed("com.spotify.xirp"))
    #expect(PaneApps.bundleIDs.count == 17)
}

@Test func rejectsNearMisses() {
    #expect(!PaneApps.isAllowed("com.jetbrains"))
    #expect(!PaneApps.isAllowed("com.jetbrainsfake.ide"))
    #expect(!PaneApps.isAllowed("org.com.jetbrains.intellij"))
    #expect(!PaneApps.isAllowed("com.microsoft.VSCode.helper"))
}
