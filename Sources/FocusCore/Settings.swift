import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Engine/actuator knobs only (spec §8–9). App behaviour and one-shot flags (camera, hot key,
/// launch at login, onboarding, notified displays) live in `AppSettings`, which wraps this as
/// `engine`. Durations in seconds, margins as fractions of display width. Ranges are the
/// typingPause 1…10, headTurn 0.3…0.7.
public struct FocusSettings: Codable, Sendable, Equatable {
    /// Screens may switch this long after the last keystroke even while panes wait `typingPause`
    public static let screenTypingPause = 1.0

    public var screenDwell = 0.3
    public var paneDwell = 0.3
    public var waitWhileTyping = true
    public var typingPause = 3.0
    public var mousePause = 1.5
    public var headTurn = 0.5
    public var offScreenDistance = 0.35
    public var minConfidence = 0.5
    public var windowFocus = true
    public var paneFocus = true
    public var syntheticClickFallback = true
    public var learnFromClicks = true
    public var windowStickMargin = 0.05
    public var paneBoundaryMargin = 0.05
    public var minWindowSize = CGSize(width: 200, height: 150)

    public init() {}
}

extension FocusSettings {
    /// Tolerant: a missing, renamed or mistyped key keeps its default instead of failing the
    /// whole file, so adding a setting never resets the user's others (plan-1 follow-up).
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        read(.screenDwell, &screenDwell); read(.paneDwell, &paneDwell); read(.waitWhileTyping, &waitWhileTyping)
        read(.typingPause, &typingPause); read(.mousePause, &mousePause); read(.headTurn, &headTurn)
        read(.offScreenDistance, &offScreenDistance); read(.minConfidence, &minConfidence)
        read(.windowFocus, &windowFocus); read(.paneFocus, &paneFocus)
        read(.syntheticClickFallback, &syntheticClickFallback); read(.learnFromClicks, &learnFromClicks)
        read(.windowStickMargin, &windowStickMargin); read(.paneBoundaryMargin, &paneBoundaryMargin)
        read(.minWindowSize, &minWindowSize)
    }
}

/// Timestamps of the last keyboard and pointer events (never their content), in seconds on the
/// host monotonic clock (CACurrentMediaTime base) — the same clock as `GazeSample.time` and
/// `FocusEngine.recordClick(time:)`.
public struct InputActivity: Sendable {
    public var lastKey: Double
    public var lastMouse: Double

    public init(lastKey: Double = -.infinity, lastMouse: Double = -.infinity) {
        self.lastKey = lastKey; self.lastMouse = lastMouse
    }

    /// The mouse always wins for `mousePause`; typing only holds screens for `screenTypingPause`.
    public func allowsScreenSwitch(at now: Double, _ s: FocusSettings) -> Bool {
        now - lastMouse >= s.mousePause && (!s.waitWhileTyping || now - lastKey >= FocusSettings.screenTypingPause)
    }

    /// Windows and panes of the current screen wait the full `typingPause`, so reading another
    /// pane mid-sentence never steals keystrokes.
    public func allowsSameScreen(at now: Double, _ s: FocusSettings) -> Bool {
        now - lastMouse >= s.mousePause && (!s.waitWhileTyping || now - lastKey >= s.typingPause)
    }
}
