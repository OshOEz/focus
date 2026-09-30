import AppKit
import FocusCore

/// The eye in the menu bar. The menu is rebuilt each time it opens (menuNeedsUpdate), so it always reflects
/// the current displays, calibrations and shortcut without any observation plumbing.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        update()
    }

    func update() {
        // A notice nobody could be shown as a notification: badge the eye until it is dealt with.
        let symbol = app.notifier.pending.isEmpty ? app.status.symbol : "eye.trianglebadge.exclamationmark"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Focus: \(app.status.title)")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Focus: \(app.status.title)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: app.status.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for n in app.notifier.pending {
            // Only the notices `open(_:)` answers with a calibration need one to be possible right now;
            // `.setupSwitched` is informational (clicking it just dismisses it) and stays enabled.
            let needsCalibration = if case .setupSwitched = n { false } else { true }
            add(menu, "⚠︎ \(n.title(n.display.flatMap { app.names[$0] }))",
                enabled: !needsCalibration || app.canCalibrate) { [unowned self] in app.open(n) }
        }
        menu.addItem(.separator())

        let hk = app.settings.hotKey
        let pause = add(menu, app.conditions.userPaused ? "Resume Focus" : "Pause Focus") { [unowned self] in app.togglePause() }
        pause.keyEquivalent = hk.key.lowercased()
        pause.keyEquivalentModifierMask = Self.flags(hk.modifiers)

        let recal = NSMenuItem(title: "Recalibrate", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let canCalibrate = app.canCalibrate
        add(sub, "All Screens…", enabled: canCalibrate) { [unowned self] in app.startCalibration([]) }
        sub.addItem(.separator())
        for d in app.displays {
            let name = app.names[d.key] ?? "Display"
            let title = app.calibratedKeys.contains(d.key) ? "\(name)…" : "\(name) (not calibrated)…"
            add(sub, title, enabled: canCalibrate) { [unowned self] in app.startCalibration([d.key]) }
        }
        let fresh = app.displays.map(\.key).filter { !app.calibratedKeys.contains($0) }
        if !fresh.isEmpty, !app.calibratedKeys.isEmpty {
            add(sub, "Calibrate New Screens…", enabled: canCalibrate) { [unowned self] in app.startCalibration(fresh) }
        }
        recal.submenu = sub
        menu.addItem(recal)
        menu.addItem(app.setups.menuItem())
        menu.addItem(.separator())
        add(menu, "Settings…", key: ",") { [unowned self] in app.showSettings() }
        add(menu, "Setup Guide…") { [unowned self] in app.showOnboarding() }
        menu.addItem(.separator())
        add(menu, "Quit Focus", key: "q") { NSApp.terminate(nil) }
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, key: String = "", enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? #selector(menuAction(_:)) : nil, keyEquivalent: key)
        i.target = self
        i.representedObject = Action(run)
        i.isEnabled = enabled
        menu.addItem(i)
        return i
    }

    @objc private func menuAction(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }

    private final class Action { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }

    static func flags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & HotKeySpec.command != 0 { f.insert(.command) }
        if carbon & HotKeySpec.shift != 0 { f.insert(.shift) }
        if carbon & HotKeySpec.option != 0 { f.insert(.option) }
        if carbon & HotKeySpec.control != 0 { f.insert(.control) }
        return f
    }
}
