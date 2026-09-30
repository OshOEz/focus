import Foundation

/// When the app should tell the user something. Pure: the caller keeps the
/// "already notified" sets (`AppSettings.notifiedDisplays` for new displays; per calibration for
/// drift, cleared when that display is recalibrated).
public enum NotificationPolicy {
    /// Connected, uncalibrated displays not announced yet: once per display, ever.
    public static func newDisplays(present: [String], calibrated: Set<String>, notified: Set<String>) -> [String] {
        present.filter { !calibrated.contains($0) && !notified.contains($0) }
    }

    /// Displays whose click error says the calibration drifted, minus those already warned about.
    public static func drifted(_ cals: [String: DisplayCalibration], notified: Set<String>) -> [String] {
        cals.filter { $0.value.needsRecalibration && !notified.contains($0.key) }.map(\.key).sorted()
    }

    /// Same screens, different arrangement (calibrations are probably off). Adding or removing a
    /// screen is not a layout change; that's "new display" or a setup change.
    public static func layoutChanged(from old: [DisplayFingerprint], to new: [DisplayFingerprint]) -> Bool {
        func identity(_ d: DisplayFingerprint) -> String { "\(d.vendor)-\(d.model)-\(d.serial)-\(d.width)x\(d.height)" }
        return old.map(identity).sorted() == new.map(identity).sorted() && Set(old) != Set(new)
    }
}
