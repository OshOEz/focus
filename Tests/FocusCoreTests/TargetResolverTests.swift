import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let left = WindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 800))
private let right = WindowInfo(id: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 800))
private let tiny = WindowInfo(id: 3, frame: CGRect(x: 700, y: 100, width: 100, height: 100))
private let s = FocusSettings()

@Test func localGlobalRoundTrip() {
    let f = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
    #expect(globalPoint(CGPoint(x: 0.5, y: 0.25), in: f) == CGPoint(x: 2000, y: 250))
    #expect(localPoint(CGPoint(x: 2000, y: 250), in: f) == CGPoint(x: 0.5, y: 0.25))
}

@Test func picksTopmostWindowUnderPoint() {
    let id = TargetResolver.window(at: CGPoint(x: 750, y: 400), windows: [right, left], current: nil, display: display, settings: s)
    #expect(id == 2)
}

@Test func currentWindowIsStickyWithinMargin() {
    // 40 pt past the left window's edge, margin is 5 % of 1000 = 50 pt.
    let id = TargetResolver.window(at: CGPoint(x: 540, y: 400), windows: [right, left], current: 1, display: display, settings: s)
    #expect(id == 1)
}

@Test func ignoresTinyWindows() {
    let id = TargetResolver.window(at: CGPoint(x: 750, y: 150), windows: [tiny, right], current: nil, display: display, settings: s)
    #expect(id == 2)
}

@Test func paneNeedsTwoPanesAndClearMargin() {
    let panes = [CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 500, y: 0, width: 500, height: 800)]
    #expect(TargetResolver.pane(at: CGPoint(x: 800, y: 400), panes: panes, display: display, settings: s) == 1)
    #expect(TargetResolver.pane(at: CGPoint(x: 520, y: 400), panes: panes, display: display, settings: s) == nil)
    #expect(TargetResolver.pane(at: CGPoint(x: 100, y: 400), panes: [panes[0]], display: display, settings: s) == nil)
}
