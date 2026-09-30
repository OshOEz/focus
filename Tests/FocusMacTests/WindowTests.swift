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
    let actuator = FocusActuator(windows: WindowProvider())
    let world = World(displays: [DisplayInfo(key: "X", frame: CGRect(x: 0, y: 0, width: 100, height: 100))],
                      windows: [], focusedWindowID: nil)
    #expect(!actuator.perform(.window(0xFFFF_FFF0), world: world))   // no such window
    #expect(!actuator.perform(.display("missing"), world: world))    // no such display
    #expect(!actuator.perform(.pane(window: 1, frame: .zero), world: world))   // plan 4 not installed
}
