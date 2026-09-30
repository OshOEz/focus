import Foundation

/// Everything the menu bar status depends on, gathered by AppController. `facing` and `driftDisplay`
/// hold display *names* (what the user reads), not keys.
public struct AppConditions: Equatable, Sendable {
    public var userPaused = false
    public var suspended = false            // locked, asleep, screensaver or another user's session
    public var cameraGranted = false
    public var accessibilityGranted = false
    public var cameraAvailable = true       // false after the camera failed to start or its stream ended
    public var calibrating = false
    public var displayCount = 1
    public var calibratedDisplays = 0       // connected displays that have a calibration
    public var windowFocus = true
    public var faceSeen = false             // a usable face in the last second
    public var facing: String?
    public var driftDisplay: String?

    public init() {}

    /// The camera runs only when its frames can be used, so the LED is off while paused, locked,
    /// uncalibrated, missing a permission, or on one screen with window focus off (nothing to do).
    /// Stays true after a camera failure so AppController keeps retrying.
    public var wantsCamera: Bool {
        guard !userPaused, !suspended, cameraGranted else { return false }
        if calibrating { return true }
        return accessibilityGranted && calibratedDisplays > 0 && !(displayCount == 1 && !windowFocus)
    }

    /// Samples go to the engine (not to a calibration). This includes "no face": the engine and the face
    /// timer must keep seeing samples to notice the face coming back.
    public var engineActive: Bool { wantsCamera && !calibrating }
}

public enum AppStatus: Equatable, Sendable {
    case paused, screenLocked, needsCamera, cameraUnavailable, calibrating, needsAccessibility,
         needsCalibration, oneDisplayWindowFocusOff, lookingForFace
    case recalibrateSuggested(String)
    case tracking(facing: String?)

    /// First match wins. User pause beats lock, so unlocking a paused Mac still reads "Paused".
    /// Camera problems come before calibrating: a dead camera is the real reason a calibration fails.
    public init(_ c: AppConditions) {
        if c.userPaused { self = .paused }
        else if c.suspended { self = .screenLocked }
        else if !c.cameraGranted { self = .needsCamera }
        else if !c.cameraAvailable { self = .cameraUnavailable }
        else if c.calibrating { self = .calibrating }
        else if !c.accessibilityGranted { self = .needsAccessibility }
        else if c.calibratedDisplays == 0 { self = .needsCalibration }
        else if c.displayCount == 1 && !c.windowFocus { self = .oneDisplayWindowFocusOff }
        else if !c.faceSeen { self = .lookingForFace }
        else if let d = c.driftDisplay { self = .recalibrateSuggested(d) }
        else { self = .tracking(facing: c.facing) }
    }

    public var title: String {
        switch self {
        case .paused: "Paused"
        case .screenLocked: "Paused while the Mac is locked or asleep"
        case .needsCamera: "Waiting for camera access"
        case .cameraUnavailable: "Can't reach the camera"
        case .calibrating: "Calibrating…"
        case .needsAccessibility: "Waiting for Accessibility access"
        case .needsCalibration: "No screen calibrated yet"
        case .oneDisplayWindowFocusOff: "One screen: switch on window and pane following in Settings"
        case .lookingForFace: "Waiting to see your face…"
        case .recalibrateSuggested(let d): "\(d) may need a new calibration"
        case .tracking(let d?): "Active · on \(d)"
        case .tracking(nil): "Active · looking away"
        }
    }

    /// SF Symbol for the template menu bar icon.
    public var symbol: String {
        switch self {
        case .tracking, .lookingForFace, .calibrating: "eye"
        case .paused, .screenLocked: "eye.slash"
        default: "eye.trianglebadge.exclamationmark"
        }
    }
}

public enum OnboardingStep: Int, CaseIterable, Sendable {
    // `places` (plan 5): reading the Wi-Fi name only helps once a setup exists, and the first one is
    // created by `calibrate` — so it sits right before, after Location has a chance to be granted.
    case welcome, permissions, places, calibrate, adjust, tryIt, done

    /// Only the permissions page blocks: nothing after it works without Camera and Accessibility.
    /// Calibration and Places can both be skipped and done later (calibration from the menu bar,
    /// Location from System Settings, prompted again by the guide).
    public func canContinue(permissionsGranted: Bool) -> Bool { self != .permissions || permissionsGranted }
    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

public enum DisplayNaming {
    /// Two identical monitors report the same localized name. Number the repeats so menus stay unambiguous.
    public static func unique(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { n in
            seen[n, default: 0] += 1
            let k = seen[n]!
            return k == 1 ? n : "\(n) (\(k))"
        }
    }
}
