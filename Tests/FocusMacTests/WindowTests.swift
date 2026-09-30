import AppKit
import Testing
import FocusCore
@testable import FocusMac

@MainActor @Test func windowListExcludesOurOwnProcess() {
    let provider = WindowProvider()
    let list = provider.windows()
    #expect(list.allSatisfy { provider.pid(for: $0.id) != getpid() })
    #expect(list.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
}

@MainActor @Test func unknownTargetsReportNoEffect() {
    let windows = WindowProvider()
    let actuator = FocusActuator(windows: windows, panes: PaneProvider(windows: windows))
    let world = World(displays: [DisplayInfo(key: "X", frame: CGRect(x: 0, y: 0, width: 100, height: 100))],
                      windows: [], focusedWindowID: nil)
    #expect(!actuator.perform(.window(0xFFFF_FFF0), world: world))   // no such window
    #expect(!actuator.perform(.display("missing"), world: world))    // no such display
    #expect(!actuator.perform(.pane(window: 1, frame: .zero), world: world))   // not a pane of the world
}

/// Audit #19: every layer counts (a floating panel above the pane blocks the click); only Focus's
/// own windows, the target, invisible (alpha 0) windows and unreadable entries are left out (R11).
@Test func occludersKeepEveryLayerButOursAndTheTarget() {
    func w(_ id: Int, pid: Int32, layer: Int, x: Int, alpha: Double? = nil) -> [String: Any] {
        // NSNumber like CGWindowListCopyWindowInfo's values (a Swift Int in Any would not cast to pid_t).
        [kCGWindowNumber as String: id as NSNumber, kCGWindowOwnerPID as String: pid as NSNumber,
         kCGWindowLayer as String: layer as NSNumber,
         kCGWindowBounds as String: CGRect(x: x, y: 0, width: 10, height: 10).dictionaryRepresentation]
            .merging(alpha.map { [kCGWindowAlpha as String: $0 as NSNumber] } ?? [:]) { $1 }
    }
    let raw = [w(1, pid: 9, layer: 0, x: 0), w(2, pid: 9, layer: 3, x: 20), w(3, pid: 9, layer: 25, x: 40),
               w(4, pid: 7, layer: 0, x: 60), w(5, pid: 9, layer: 0, x: 80), [kCGWindowNumber as String: 6 as NSNumber],
               w(7, pid: 9, layer: 25, x: 100, alpha: 0), w(8, pid: 9, layer: 0, x: 120, alpha: 0.5)]
    #expect(FocusActuator.occluders(in: raw, excludingPID: 7, window: 5).map(\.minX) == [0, 20, 40, 120])
}

/// The Dock owns an always-on, click-through window spanning the whole display at layer 20 with
/// alpha 1 (bench 4, 2026-09-30): it must not count, or no pane click ever finds a safe point.
/// Its real bar is passed in as `dockStrips` and counts only when the Dock is above the target.
@Test func dockWindowIsReplacedByItsStrips() {
    func w(_ id: Int, owner: String, bounds: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id as NSNumber, kCGWindowOwnerPID as String: 9 as NSNumber,
         kCGWindowOwnerName as String: owner, kCGWindowLayer as String: 20 as NSNumber,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let strip = CGRect(x: 0, y: 900, width: 1512, height: 82)
    let panel = CGRect(x: 30, y: 0, width: 10, height: 10)
    let above = [w(1, owner: "Dock", bounds: display), w(2, owner: "Panel", bounds: panel)]
    #expect(FocusActuator.occluders(in: above, excludingPID: 7, window: 5, dockStrips: [strip], displayFrames: [display])
            == [panel, strip])
    // Dock not above the target: its strip can't cover the click.
    #expect(FocusActuator.occluders(in: [w(2, owner: "Panel", bounds: panel)], excludingPID: 7, window: 5,
                                    dockStrips: [strip], displayFrames: [display]).count == 1)
}

/// Only the Dock's invisible click-through window (bounds equal to a whole display) is dropped:
/// its real UI is layer 20 too but sized to content, and must still block a click underneath it —
/// dropping it (the old, too-broad rule) meant no pane click ever found a safe point when the Dock
/// showed its running-apps menu or a Stage Manager stack popup above the target.
@Test func dockUIWindowStaysAnOccluderOnlyItsInvisibleWindowDoesnt() {
    func w(_ id: Int, bounds: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id as NSNumber, kCGWindowOwnerPID as String: 9 as NSNumber,
         kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 20 as NSNumber,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let popup = CGRect(x: 600, y: 400, width: 300, height: 300)
    #expect(FocusActuator.occluders(in: [w(1, bounds: popup)], excludingPID: 7, window: 5, displayFrames: [display]) == [popup])
    #expect(FocusActuator.occluders(in: [w(2, bounds: display)], excludingPID: 7, window: 5, displayFrames: [display]).isEmpty)
}

/// Audit #27: Launchpad, Mission Control and any other full-display Dock window block the click —
/// only the permanent window's own layer (20, bench 4 2026-09-30) is dropped. Same bounds, different
/// layer (27 here, arbitrary) must still come back as an occluder, or an overlay the user opened on
/// purpose could eat a click meant for the pane underneath (R11).
@Test func fullDisplayDockWindowAtAnyOtherLayerStaysAnOccluder() {
    func w(_ id: Int, layer: Int, bounds: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id as NSNumber, kCGWindowOwnerPID as String: 9 as NSNumber,
         kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: layer as NSNumber,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    #expect(FocusActuator.occluders(in: [w(1, layer: 27, bounds: display)], excludingPID: 7, window: 5,
                                    displayFrames: [display]) == [display])
    // The permanent window itself (layer 20) is still the one that's dropped.
    #expect(FocusActuator.occluders(in: [w(2, layer: 20, bounds: display)], excludingPID: 7, window: 5,
                                    displayFrames: [display]).isEmpty)
}

/// NSScreen frame / visibleFrame (Cocoa, bottom-left origin) → the Dock's strip in global CG
/// coordinates. The top gap is the menu bar, never the Dock; auto-hide leaves no strip.
@Test func dockStripFromVisibleFrame() {
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982), h = 982.0
    // Bottom Dock 70 pt, menu bar 33 pt.
    #expect(FocusActuator.dockStrip(frame: frame, visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879), primaryHeight: h)
            == CGRect(x: 0, y: 912, width: 1512, height: 70))
    // Left Dock 60 pt.
    #expect(FocusActuator.dockStrip(frame: frame, visibleFrame: CGRect(x: 60, y: 0, width: 1452, height: 949), primaryHeight: h)
            == CGRect(x: 0, y: 0, width: 60, height: 982))
    // Right Dock 60 pt.
    #expect(FocusActuator.dockStrip(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1452, height: 949), primaryHeight: h)
            == CGRect(x: 1452, y: 0, width: 60, height: 982))
    // Auto-hide: only the menu bar is taken.
    #expect(FocusActuator.dockStrip(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), primaryHeight: h) == nil)
    // Secondary screen above the primary (Cocoa y 982…2062), bottom Dock 70 pt → CG y −1080…0.
    let top = CGRect(x: 0, y: 982, width: 1920, height: 1080)
    #expect(FocusActuator.dockStrip(frame: top, visibleFrame: CGRect(x: 0, y: 1052, width: 1920, height: 977), primaryHeight: h)
            == CGRect(x: 0, y: -70, width: 1920, height: 70))
}
