import AppKit
import CoreGraphics

/// Tracking (and the camera) stops while the Mac is locked, asleep, showing the screensaver or
/// switched to another user. Several reasons can overlap; tracking resumes when the
/// last one ends.
@MainActor public final class SystemStateMonitor {
    public enum Reason: String, Sendable, CaseIterable { case locked, asleep, displaysAsleep, screensaver, sessionInactive }

    public private(set) var reasons: Set<Reason> = []
    public var isSuspended: Bool { !reasons.isEmpty }
    /// Called with the new `isSuspended`, only when it flips.
    public var onChange: ((Bool) -> Void)?
    /// Written only in init; deinit (nonisolated) removes the observers it added there.
    private nonisolated(unsafe) var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    /// (notification, reason, starts?, distributed?)
    private static let events: [(String, Reason, Bool, Bool)] = [
        ("com.apple.screenIsLocked", .locked, true, true), ("com.apple.screenIsUnlocked", .locked, false, true),
        ("com.apple.screensaver.didstart", .screensaver, true, true), ("com.apple.screensaver.didstop", .screensaver, false, true),
        (NSWorkspace.willSleepNotification.rawValue, .asleep, true, false),
        (NSWorkspace.didWakeNotification.rawValue, .asleep, false, false),
        (NSWorkspace.screensDidSleepNotification.rawValue, .displaysAsleep, true, false),
        (NSWorkspace.screensDidWakeNotification.rawValue, .displaysAsleep, false, false),
        (NSWorkspace.sessionDidResignActiveNotification.rawValue, .sessionInactive, true, false),
        (NSWorkspace.sessionDidBecomeActiveNotification.rawValue, .sessionInactive, false, false),
    ]

    public init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                distributed: NotificationCenter = DistributedNotificationCenter.default(),
                initiallyLocked: Bool = SystemStateMonitor.screenIsLocked()) {
        if initiallyLocked { reasons.insert(.locked) }
        for (name, reason, starts, isDistributed) in Self.events {
            let center = isDistributed ? distributed : workspace
            let token = center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(reason, starts) }
            }
            tokens.append((center, token))
        }
    }

    deinit { for (c, t) in tokens { c.removeObserver(t) } }

    private func set(_ reason: Reason, _ active: Bool) {
        let was = isSuspended
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        if was != isSuspended { onChange?(isSuspended) }
    }

    /// A login item can start before the first unlock: read the current state instead of waiting
    /// for a notification that already happened.
    public nonisolated static func screenIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
