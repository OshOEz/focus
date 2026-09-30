import Testing
import FocusCore
@testable import FocusMac

/// Substitute for the brief's live bench check (Sources/FocusBench doesn't exist in this checkout yet — the
/// E4 bench harness, plan 3a Task 11, lands on a separate branch). Reads permission status only, never requests.
@MainActor @Test func fingerprintPassesDisplaysAndCameraIDThrough() {
    let displays = [DisplayFingerprint(vendor: 1, model: 2, serial: 3, width: 1920, height: 1080, originX: 0, originY: 0)]
    let fp = EnvironmentFingerprinter.current(displays: displays, cameraID: "test-camera")
    #expect(fp.displays == displays)
    #expect(fp.cameraID == "test-camera")
}

@Test func wifiSSIDReadsNilWithoutLocationPermission() {
    // Machine fact (global-constraints.md): Location is not granted in this environment, so this never prompts
    // and always takes the nil branch — the one CoreWLAN path this suite can exercise without Location.
    #expect(Permissions.location != .granted)
    #expect(EnvironmentFingerprinter.wifiSSID() == nil)
}
