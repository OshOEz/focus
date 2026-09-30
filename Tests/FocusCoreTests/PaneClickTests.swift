import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private let display = DisplayInfo(key: "d", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
private let win = WindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 400))
private let narrow = CGRect(x: 0, y: 0, width: 100, height: 400)
private let wide = CGRect(x: 100, y: 0, width: 900, height: 400)

private func world(_ windows: [WindowInfo] = [win]) -> World {
    World(displays: [display], windows: windows, focusedWindowID: 1, panes: [narrow, wide], focusedPane: 0)
}

@Test func clicksAtTheCentreOfASafePane() {
    #expect(PaneClick.point(for: wide, window: 1, world: world()) == CGPoint(x: 550, y: 200))
}

@Test func noClickNearAnotherPane() {
    // Centre x = 50; the wide pane starts at 100, margin = 5 % of 1000 = 50 pt → too close to the divider.
    #expect(PaneClick.point(for: narrow, window: 1, world: world()) == nil)
}

@Test func noClickWhenAnotherWindowCoversTheCentre() {
    let floating = WindowInfo(id: 9, frame: CGRect(x: 500, y: 150, width: 100, height: 100))
    #expect(PaneClick.point(for: wide, window: 1, world: world([floating, win])) == nil)
}

@Test func noClickWhenAFloatingWindowOutsideWorldWindowsCoversTheCentre() {
    // #19: World.windows only ever holds layer-0 windows (WindowProvider drops higher layers
    // and Focus itself), so a floating panel (NSPanel .floating, PiP, a visio mini-window) never
    // shows up there — it must still block the click via the explicit `occluders` list.
    let floatingPanel = CGRect(x: 500, y: 150, width: 100, height: 100)
    #expect(PaneClick.point(for: wide, window: 1, world: world(), occluders: [floatingPanel]) == nil)
}

@Test func noClickForAPaneTheWorldDoesNotKnow() {
    #expect(PaneClick.point(for: CGRect(x: 0, y: 500, width: 400, height: 200), window: 1, world: world()) == nil)
}

@Test func noClickOffEveryDisplay() {
    var w = world()
    w.displays = []
    #expect(PaneClick.point(for: wide, window: 1, world: w) == nil)
}

@Test func paneSettingsDecodeTolerantlyAndClamp() throws {
    let a = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"paneDwell": 5}"#.utf8))
    #expect(a.paneDwell == 1.5)
    #expect(a.syntheticClickFallback)
    let b = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"paneDwell": 0.05, "syntheticClickFallback": false}"#.utf8))
    #expect(b.paneDwell == 0.2)
    #expect(!b.syntheticClickFallback)
}
