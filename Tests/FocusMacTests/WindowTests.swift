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
