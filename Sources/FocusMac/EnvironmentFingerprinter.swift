import CoreWLAN
import FocusCore

/// Reads where the Mac is, for setup matching (spec §7): screens, the camera in use, and the Wi-Fi name.
public enum EnvironmentFingerprinter {
    @MainActor
    public static func current(displays: [DisplayFingerprint], cameraID: String) -> Fingerprint {
        Fingerprint(displays: displays, cameraID: cameraID, wifiSSID: wifiSSID())
    }

    /// Since macOS 14, CoreWLAN returns nil for the SSID unless the app may use Location. We check the grant
    /// first so "no permission" is an explicit nil instead of CoreWLAN's silent one; reading status never prompts.
    public static func wifiSSID() -> String? {
        guard Permissions.location == .granted else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }
}
