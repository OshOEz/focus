import UserNotifications

enum FocusNotice: Hashable {
    case drift(String)        // display key
    case newDisplay(String)   // display key
    case layoutChanged

    var display: String? {
        switch self {
        case .drift(let k), .newDisplay(let k): k
        case .layoutChanged: nil
        }
    }

    /// Stable per notice, so a repost replaces the banner instead of stacking a second one.
    var id: String {
        switch self {
        case .drift(let k): "drift-\(k)"
        case .newDisplay(let k): "new-\(k)"
        case .layoutChanged: "layout"
        }
    }

    func title(_ name: String?) -> String {
        let name = name ?? "a screen"
        return switch self {
        case .drift: "Off target on \(name)"
        case .newDisplay: "New screen connected: \(name)"
        case .layoutChanged: "Screens moved"
        }
    }

    func body(_ name: String?) -> String {
        let name = name ?? "that screen"
        return switch self {
        case .drift: "Your clicks keep landing away from where Focus expects your gaze. Recalibrate \(name)."
        case .newDisplay: "Focus ignores it until you calibrate it; the screens you already set up carry on as before."
        case .layoutChanged: "If focus lands on the wrong screen, recalibrate all screens."
        }
    }
}

/// Posts notices as system notifications when allowed; otherwise keeps them in `pending` for the menu.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((FocusNotice) -> Void)?
    /// Called whenever `pending` may have changed, so the status item can refresh its icon.
    var onChange: (() -> Void)?
    private(set) var pending: [FocusNotice] = []
    /// UNUserNotificationCenter raises without a bundle id (`swift run`): no center, everything goes to the menu.
    private let center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil

    override init() {
        super.init()
        center?.delegate = self
    }

    /// Asks for permission. Only the Setup Guide's final button calls this, never a launch.
    func requestAuthorization() async {
        _ = try? await center?.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ n: FocusNotice, name: String?) {
        Task {
            let status = await center?.notificationSettings().authorizationStatus
            if let center, status == .authorized || status == .provisional {
                let content = UNMutableNotificationContent()
                content.title = n.title(name)
                content.body = n.body(name)
                content.userInfo = Self.userInfo(n)
                try? await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
            } else if !pending.contains(n) {
                pending.append(n)
            }
            onChange?()
        }
    }

    /// Removes `n` from the menu once it has been acted on (or no longer applies), and withdraws its
    /// delivered banner (if any): a stale "new screen"/drift notice shouldn't linger in Notification Center.
    func take(_ n: FocusNotice) {
        center?.removeDeliveredNotifications(withIdentifiers: [n.id])
        guard let i = pending.firstIndex(of: n) else { return }
        pending.remove(at: i)
        onChange?()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let n = Self.notice(kind: info["kind"] as? String, display: info["display"] as? String) else { return }
        await MainActor.run { onOpen?(n) }
    }

    private static func userInfo(_ n: FocusNotice) -> [String: String] {
        let kind = switch n { case .drift: "drift"; case .newDisplay: "newDisplay"; case .layoutChanged: "layoutChanged" }
        return ["kind": kind, "display": n.display ?? ""]
    }

    nonisolated private static func notice(kind: String?, display: String?) -> FocusNotice? {
        switch (kind, display) {
        case ("drift", let k?): .drift(k)
        case ("newDisplay", let k?): .newDisplay(k)
        case ("layoutChanged", _): .layoutChanged
        default: nil
        }
    }
}
