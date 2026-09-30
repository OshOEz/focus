import UserNotifications

enum FocusNotice: Hashable {
    case drift(String)        // display key
    case newDisplay(String)   // display key
    case layoutChanged
    case setupSwitched(String, ambiguous: Bool)   // setup name
    case newPlace

    var display: String? {
        switch self {
        case .drift(let k), .newDisplay(let k): k
        case .layoutChanged, .setupSwitched, .newPlace: nil
        }
    }

    /// Stable per notice, so a repost replaces the banner instead of stacking a second one.
    var id: String {
        switch self {
        case .drift(let k): "drift-\(k)"
        case .newDisplay(let k): "new-\(k)"
        case .layoutChanged: "layout"
        case .setupSwitched: "setup-switched"
        case .newPlace: "new-place"
        }
    }

    func title(_ name: String?) -> String {
        let name = name ?? "a screen"
        return switch self {
        case .drift: "Off target on \(name)"
        case .newDisplay: "New screen connected: \(name)"
        case .layoutChanged: "Screens moved"
        case .setupSwitched(let setupName, _): "Now using \u{201C}\(setupName)\u{201D}"
        case .newPlace: "New place detected"
        }
    }

    func body(_ name: String?) -> String {
        let name = name ?? "that screen"
        return switch self {
        case .drift: "Your clicks keep landing away from where Focus expects your gaze. Recalibrate \(name)."
        case .newDisplay: "Focus ignores it until you calibrate it; the screens you already set up carry on as before."
        case .layoutChanged: "If focus lands on the wrong screen, recalibrate all screens."
        case .setupSwitched(_, let ambiguous):
            ambiguous ? "More than one setup fits this place. If this one is wrong, pick another under Setup in the menu."
                      : "Focus recognised this place and loaded its calibration."
        case .newPlace: "These screens and this camera don't match a saved setup, so tracking is paused. Calibrate to start here."
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
    /// What clicking the current "new place detected" notice should do; AppController.open(_:) reads this
    /// (a closure, not something a userInfo round-trip can carry — see `notice(kind:display:)`).
    var newPlaceAction: (@MainActor () -> Void)?
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

    /// Only the latest switch matters: an older one still sitting in `pending` (never delivered, or
    /// delivered and dismissed without being clicked) would otherwise pile up, one per place change, with no
    /// way to clear them from the menu. `take` matches by id, which is stable regardless of `name`/`ambiguous`.
    func setupSwitched(to name: String, ambiguous: Bool) {
        if let old = pending.first(where: { if case .setupSwitched = $0 { true } else { false } }) { take(old) }
        post(.setupSwitched(name, ambiguous: ambiguous), name: nil)
    }

    /// `onCalibrate` is stashed for `AppController.open(.newPlace)`, whether the click arrives from a
    /// delivered banner or from the pending list in the menu.
    func newPlaceDetected(onCalibrate: @escaping @MainActor () -> Void) {
        newPlaceAction = onCalibrate
        post(.newPlace, name: nil)
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
        let kind = switch n {
        case .drift: "drift"; case .newDisplay: "newDisplay"; case .layoutChanged: "layoutChanged"
        case .setupSwitched: "setupSwitched"; case .newPlace: "newPlace"
        }
        return ["kind": kind, "display": n.display ?? ""]
    }

    nonisolated private static func notice(kind: String?, display: String?) -> FocusNotice? {
        switch (kind, display) {
        case ("drift", let k?): .drift(k)
        case ("newDisplay", let k?): .newDisplay(k)
        case ("layoutChanged", _): .layoutChanged
        // setupSwitched isn't reconstructed from a delivered banner: its name/ambiguity aren't in userInfo
        // (only "kind"/"display" round-trip) and clicking it has nothing to do anyway (see AppController.open).
        case ("newPlace", _): .newPlace
        default: nil
        }
    }
}
