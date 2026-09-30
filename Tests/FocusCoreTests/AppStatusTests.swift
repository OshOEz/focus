import Foundation
import Testing
@testable import FocusCore

@Suite struct AppStatusTests {
    /// Everything granted, one calibrated screen of two, face in view.
    private func ready() -> AppConditions {
        var c = AppConditions()
        c.cameraGranted = true
        c.accessibilityGranted = true
        c.displayCount = 2
        c.calibratedDisplays = 2
        c.faceSeen = true
        c.facing = "Studio Display"
        return c
    }

    @Test func tracksWhenEverythingIsReady() {
        let c = ready()
        #expect(AppStatus(c) == .tracking(facing: "Studio Display"))
        #expect(AppStatus(c).title == "Active · on Studio Display")
        #expect(c.wantsCamera && c.engineActive)
        var away = c
        away.facing = nil
        #expect(AppStatus(away).title == "Active · looking away")
    }

    @Test func userPauseWinsOverLock() {
        var c = ready()
        c.userPaused = true
        c.suspended = true
        #expect(AppStatus(c) == .paused)
        #expect(!c.wantsCamera)
        c.userPaused = false
        #expect(AppStatus(c) == .screenLocked)
        #expect(!c.wantsCamera)
    }

    @Test func permissionsComeBeforeCalibration() {
        var c = ready()
        c.calibratedDisplays = 0
        c.cameraGranted = false
        #expect(AppStatus(c) == .needsCamera)
        c.cameraGranted = true
        c.accessibilityGranted = false
        #expect(AppStatus(c) == .needsAccessibility)
        #expect(!c.wantsCamera)
        c.accessibilityGranted = true
        #expect(AppStatus(c) == .needsCalibration)
        #expect(!c.wantsCamera)
    }

    @Test func calibratingNeedsOnlyCamera() {
        var c = ready()
        c.accessibilityGranted = false
        c.calibratedDisplays = 0
        c.calibrating = true
        #expect(AppStatus(c) == .calibrating)
        #expect(c.wantsCamera)
        #expect(!c.engineActive)
    }

    @Test func oneDisplayWithoutWindowFocusKeepsCameraOff() {
        var c = ready()
        c.displayCount = 1
        c.calibratedDisplays = 1
        c.windowFocus = false
        #expect(AppStatus(c) == .oneDisplayWindowFocusOff)
        #expect(!c.wantsCamera)
    }

    @Test func lostCameraKeepsRetrying() {
        var c = ready()
        c.cameraAvailable = false
        #expect(AppStatus(c) == .cameraUnavailable)
        #expect(c.wantsCamera)   // AppController retries while this stays true
    }

    @Test func faceThenDrift() {
        var c = ready()
        c.faceSeen = false
        c.driftDisplay = "DELL U2720Q"
        #expect(AppStatus(c) == .lookingForFace)
        #expect(c.engineActive)  // samples keep flowing so a returning face is noticed
        c.faceSeen = true
        #expect(AppStatus(c) == .recalibrateSuggested("DELL U2720Q"))
        #expect(AppStatus(c).symbol == "eye.trianglebadge.exclamationmark")
    }

    @Test func onlyPermissionsStepBlocks() {
        #expect(!OnboardingStep.permissions.canContinue(permissionsGranted: false))
        #expect(OnboardingStep.permissions.canContinue(permissionsGranted: true))
        #expect(OnboardingStep.calibrate.canContinue(permissionsGranted: false))
        #expect(OnboardingStep.allCases.count == 6)
        #expect(OnboardingStep.done.next == nil && OnboardingStep.welcome.previous == nil)
    }

    @Test func duplicateDisplayNamesAreNumbered() {
        #expect(DisplayNaming.unique(["DELL", "Built-in", "DELL", "DELL"]) == ["DELL", "Built-in", "DELL (2)", "DELL (3)"])
    }
}
