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
        let image = NSImage(systemSymbolName: app.status.symbol, accessibilityDescription: "Focus: \(app.status.title)")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Focus: \(app.status.title)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: app.status.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let hk = app.settings.hotKey
        let pause = add(menu, app.conditions.userPaused ? "Resume Focus" : "Pause Focus") { [unowned self] in app.togglePause() }
        pause.keyEquivalent = hk.key.lowercased()
        pause.keyEquivalentModifierMask = Self.flags(hk.modifiers)

        let recal = NSMenuItem(title: "Recalibrate", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let canCalibrate = app.conditions.cameraGranted && app.calibration == nil
        add(sub, "All Screens…", enabled: canCalibrate && !app.displays.isEmpty) { [unowned self] in app.startCalibration([]) }
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
        // T8 inserts "Settings…" (⌘,) and T7 "Setup Guide…" here, after a separator. Plan 5 adds "Setups" above Recalibrate.
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
