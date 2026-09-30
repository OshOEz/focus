import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreLocation

/// Permission status for the status line and onboarding. The status getters never prompt; the
/// request functions do and are called only from onboarding, with a human in front of it
/// (never from tests or benches: scripts/bench.sh greps for them).
public enum Permissions {
    public enum Status: Sendable, Equatable { case granted, denied, notDetermined }

    /// System Settings › Privacy & Security anchors.
    public enum Pane: String, Sendable {
        case camera = "Privacy_Camera", accessibility = "Privacy_Accessibility", location = "Privacy_LocationServices"
    }

    public static var camera: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Accessibility has no "not determined": an untrusted app reads as denied.
    public static var accessibility: Status { AXIsProcessTrusted() ? .granted : .denied }

    /// Only Focus's Wi-Fi setups need it (SSID); optional (plan 5).
    public static var location: Status {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: .notDetermined
        case .restricted, .denied: .denied
        default: .granted
        }
    }

    /// Posting synthetic events (plan 4's click fallback, bench 4). Granted with Accessibility in practice.
    public static var eventPosting: Status { CGPreflightPostEventAccess() ? .granted : .denied }

    public static func requestCamera() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    /// Shows the system "open System Settings" alert; the onboarding page then polls `accessibility`.
    public static func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!)
    }

    /// Kept alive until the user answers the prompt, or macOS drops it; onboarding's Places step polls
    /// `location` once a second instead of using a delegate.
    @MainActor private static var locationManager: CLLocationManager?

    /// Onboarding's Places step only.
    @MainActor public static func requestLocation() {
        let manager = CLLocationManager()
        locationManager = manager
        manager.requestWhenInUseAuthorization()
    }
}
