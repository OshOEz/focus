import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// User-tunable knobs (spec §8–9). Durations in seconds, margins as fractions of display width.
public struct FocusSettings: Codable, Sendable, Equatable {
    public var screenDwell = 0.3
    public var paneDwell = 0.3
    public var typingPause = 3.0
    public var mousePause = 1.5
    public var hysteresis = 0.25
    public var offScreenDistance = 0.35
    public var minConfidence = 0.5
    public var windowFocus = true
    public var paneFocus = true
    public var windowStickMargin = 0.05
    public var paneBoundaryMargin = 0.05
    public var minWindowSize = CGSize(width: 200, height: 150)

    public init() {}
}

/// Timestamps of the last keyboard and pointer events (never their content).
public struct InputActivity: Sendable {
    public var lastKey = -Double.infinity
    public var lastMouse = -Double.infinity

    public init() {}

    public func isQuiet(at now: Double, _ s: FocusSettings) -> Bool {
        now - lastKey >= s.typingPause && now - lastMouse >= s.mousePause
    }
}
