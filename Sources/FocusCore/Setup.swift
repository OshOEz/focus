import Foundation

public struct DisplayFingerprint: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var width: Int
    public var height: Int
    public var originX: Int
    public var originY: Int

    public init(vendor: UInt32, model: UInt32, serial: UInt32, width: Int, height: Int, originX: Int, originY: Int) {
        self.vendor = vendor; self.model = model; self.serial = serial
        self.width = width; self.height = height; self.originX = originX; self.originY = originY
    }

    /// Stable across reboots. Monitors without a serial fall back to their position,
    /// so two identical ones don't share a calibration.
    public var key: String {
        serial != 0 ? "\(vendor)-\(model)-\(serial)" : "\(vendor)-\(model)-@\(originX),\(originY)"
    }
}

public struct Fingerprint: Codable, Equatable, Sendable {
    public var displays: [DisplayFingerprint]
    public var cameraID: String
    public var wifiSSID: String?

    public init(displays: [DisplayFingerprint], cameraID: String, wifiSSID: String?) {
        self.displays = displays; self.cameraID = cameraID; self.wifiSSID = wifiSSID
    }
}

/// A place you work from: its screens, camera, Wi-Fi and calibrations (spec §7).
public struct Setup: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var fingerprint: Fingerprint
    public var calibrations: [String: DisplayCalibration]   // by DisplayFingerprint.key

    public init(id: UUID, name: String, fingerprint: Fingerprint, calibrations: [String: DisplayCalibration]) {
        self.id = id; self.name = name; self.fingerprint = fingerprint; self.calibrations = calibrations
    }
}

public enum SetupMatch: Equatable, Sendable {
    case matched(UUID)
    case ambiguous([UUID])
    case none
}

public enum SetupMatcher {
    public static func match(_ current: Fingerprint, in setups: [Setup]) -> SetupMatch {
        let candidates = setups.filter {
            Set($0.fingerprint.displays) == Set(current.displays) && $0.fingerprint.cameraID == current.cameraID
        }
        if candidates.count == 1 { return .matched(candidates[0].id) }
        if candidates.isEmpty { return .none }
        let bySSID = candidates.filter { current.wifiSSID != nil && $0.fingerprint.wifiSSID == current.wifiSSID }
        return bySSID.count == 1 ? .matched(bySSID[0].id) : .ambiguous(candidates.map(\.id))
    }
}

extension DisplayFingerprint {
    /// `key` of each display, made unique within the list: two identical monitors reporting the
    /// same non-zero serial (cheap panels, some docks) get their origin appended, so they never
    /// share a calibration or a "last window". Unique displays keep their plain key, which is the
    /// one stable across rearrangements.
    public static func uniqueKeys(_ displays: [DisplayFingerprint]) -> [String] {
        let counts = Dictionary(displays.map { ($0.key, 1) }, uniquingKeysWith: +)
        return displays.map { counts[$0.key]! > 1 ? "\($0.key)@\($0.originX),\($0.originY)" : $0.key }
    }
}
