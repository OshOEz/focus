import Foundation

/// A global shortcut in Carbon terms: `RegisterEventHotKey` takes a virtual key code and Carbon modifier masks.
public struct HotKeySpec: Codable, Equatable, Sendable {
    // Carbon Events.h masks (cmdKey, shiftKey, optionKey, controlKey).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    /// ⇧⌘G (kVK_ANSI_G = 5), the default.
    public static let `default` = HotKeySpec(keyCode: 5, modifiers: shift | command, key: "G")

    public var keyCode: UInt32
    public var modifiers: UInt32
    /// The key as the recorder showed it, kept only for the label.
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    /// Shift alone doesn't count: ⇧+letter is ordinary typing and would be swallowed system-wide.
    public var isValid: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// Apple's canonical modifier order: ⌃⌥⇧⌘.
    public var label: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
    }
}

/// Everything in settings.json. Engine knobs are in `engine`; the rest is app behaviour and one-shot flags.
public struct AppSettings: Codable, Equatable, Sendable {
    public var engine = FocusSettings()
    /// `AVCaptureDevice.uniqueID`; nil means the built-in camera (the "Built-in (default)" entry).
    public var cameraID: String?
    public var showGazeDot = false
    public var moveCursor = true
    public var hotKey = HotKeySpec.default
    public var launchAtLogin = true
    /// Launch at login defaults to on but is registered only once, so turning it off in System Settings sticks.
    public var loginItemDefaultApplied = false
    public var onboardingCompleted = false
    /// The "new display" notice is sent once per display key, even across relaunches.
    public var notifiedDisplays: Set<String> = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case engine, cameraID, showGazeDot, moveCursor, hotKey, launchAtLogin, loginItemDefaultApplied,
             onboardingCompleted, notifiedDisplays
    }

    /// Tolerant on purpose: a missing or mistyped key keeps its default, so a file written by an older or
    /// newer build never resets every setting (plan-1 follow-up on persistence).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        engine = value(.engine, FocusSettings())
        cameraID = try? c.decodeIfPresent(String.self, forKey: .cameraID)
        showGazeDot = value(.showGazeDot, false)
        moveCursor = value(.moveCursor, true)
        hotKey = value(.hotKey, HotKeySpec.default)
        launchAtLogin = value(.launchAtLogin, true)
        loginItemDefaultApplied = value(.loginItemDefaultApplied, false)
        onboardingCompleted = value(.onboardingCompleted, false)
        notifiedDisplays = value(.notifiedDisplays, [])
    }
}

/// settings.json next to the setups folder. A file that isn't JSON at all is kept as `.broken` for inspection.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        if let s = try? JSONDecoder().decode(AppSettings.self, from: data) { return s }
        let broken = url.appendingPathExtension("broken")
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.moveItem(at: url, to: broken)
        return AppSettings()
    }

    public func save(_ s: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(s).write(to: url, options: .atomic)
    }
}
