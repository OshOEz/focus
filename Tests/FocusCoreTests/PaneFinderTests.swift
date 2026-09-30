import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import FocusCore

private struct N {
    var role = "AXGroup"
    var frame: CGRect?
    var focusable = false
    var kids: [N] = []
}

private final class Counter { var childrenCalls = 0; var frameCalls = 0 }

private func tree(_ c: Counter = Counter()) -> PaneTree<N> {
    PaneTree(role: { $0.role }, frame: { c.frameCalls += 1; return $0.frame }, isFocusable: { $0.focusable },
             children: { c.childrenCalls += 1; return $0.kids })
}

private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
private let minSize = CGSize(width: 200, height: 150)

private func find(_ window: N, _ t: PaneTree<N> = tree(), maxNodes: Int = 3000) -> [CGRect] {
    PaneFinder.panes(in: window, windowFrame: window.frame!, minSize: minSize, maxNodes: maxNodes, tree: t).map(\.frame)
}

@Test func xirpLikeTreeYieldsOnlyDeepestPanes() {
    // Shape from docs/spikes/ax-panes.md: focusable window-sized wrappers above the web area.
    let full = r(0, 33, 1512, 859)
    let button = N(role: "AXButton", frame: r(10, 110, 32, 32), focusable: true)
    let a = N(frame: r(0, 100, 605, 223), focusable: true, kids: [button])
    let b = N(frame: r(610, 100, 605, 223), focusable: true)
    let web = N(role: "AXWebArea", frame: full, focusable: true, kids: [N(frame: full, kids: [b, a])])
    var chain = web
    for _ in 0..<6 { chain = N(frame: full, focusable: true, kids: [chain]) }
    let window = N(role: "AXWindow", frame: full, kids: [chain])
    #expect(find(window) == [a.frame!, b.frame!])
}

@Test func singlePaneIsReturnedAlone() {
    let full = r(0, 0, 1258, 747)
    let web = N(role: "AXWebArea", frame: full, kids: [N(frame: full, focusable: true)])
    #expect(find(N(role: "AXWindow", frame: full, kids: [web])) == [full])
}

@Test func nativeSplitIsClippedToScrollAreas() {
    // An AXTextArea is as tall as its document; its visible part is its scroll area.
    let top = N(role: "AXScrollArea", frame: r(0, 0, 1000, 300),
                kids: [N(role: "AXTextArea", frame: r(0, 0, 1000, 5000), focusable: true)])
    let bottom = N(role: "AXScrollArea", frame: r(0, 300, 1000, 300),
                   kids: [N(role: "AXTextArea", frame: r(0, 300, 1000, 5000), focusable: true)])
    let window = N(role: "AXWindow", frame: r(0, 0, 1000, 600),
                   kids: [N(role: "AXSplitGroup", frame: r(0, 0, 1000, 600), kids: [top, bottom])])
    #expect(find(window) == [r(0, 0, 1000, 300), r(0, 300, 1000, 300)])
}

@Test func webAreaWinsOverNativeChrome() {
    let sidebar = N(frame: r(0, 0, 300, 600), focusable: true)
    let web = N(role: "AXWebArea", frame: r(300, 0, 700, 600),
                kids: [N(frame: r(300, 0, 350, 600), focusable: true), N(frame: r(650, 0, 350, 600), focusable: true)])
    let window = N(role: "AXWindow", frame: r(0, 0, 1000, 600), kids: [sidebar, web])
    #expect(find(window) == [r(300, 0, 350, 600), r(650, 0, 350, 600)])
}

@Test func smallFocusablesAreNotPanes() {
    let window = N(role: "AXWindow", frame: r(0, 0, 1000, 600),
                   kids: [N(role: "AXButton", frame: r(0, 0, 199, 600), focusable: true),
                          N(role: "AXButton", frame: r(300, 0, 600, 149), focusable: true)])
    #expect(find(window).isEmpty)
}

@Test func nilFrameGroupsPassThroughAndDuplicatesCollapse() {
    let p = N(frame: r(0, 0, 500, 600), focusable: true)
    let q = N(frame: r(500, 0, 500, 600), focusable: true)
    let window = N(role: "AXWindow", frame: r(0, 0, 1000, 600), kids: [N(frame: nil, kids: [p, p, q])])
    #expect(find(window) == [p.frame!, q.frame!])
}

@Test func smallSubtreesAreNeverVisited() {
    let c = Counter()
    let hidden = N(frame: r(0, 0, 50, 50), kids: [N(frame: r(0, 0, 900, 600), focusable: true)])
    let window = N(role: "AXWindow", frame: r(0, 0, 1000, 600), kids: [hidden])
    #expect(find(window, tree(c)).isEmpty)
    #expect(c.childrenCalls == 1)   // only the window's children were read
}

@Test func nodeBudgetBoundsTheWalk() {
    let c = Counter()
    let leaf = N(frame: r(0, 0, 900, 600), focusable: true)
    let window = N(role: "AXWindow", frame: r(0, 0, 1000, 600),
                   kids: Array(repeating: N(frame: r(0, 0, 1000, 600), kids: [leaf]), count: 100))
    _ = find(window, tree(c), maxNodes: 10)
    #expect(c.childrenCalls <= 10)
    // The budget must be spent before any AX round trip, not after — else an exhausted
    // budget still pays for one `frame` read per remaining sibling.
    #expect(c.frameCalls <= 10)
}

@Test func dialogOverThePanesIsNotAPane() {
    // Xirp's update popup: a web dialog on top of a two-terminal grid (ax-dump, 2026-09-30).
    let full = r(0, 33, 1512, 859)
    let left = N(frame: r(263, 189, 551, 223), focusable: true)
    let right = N(frame: r(827, 189, 660, 223), focusable: true)
    let dialog = N(role: "AXApplicationDialog", frame: r(532, 357, 448, 212), focusable: true)
    let web = N(role: "AXWebArea", frame: full, focusable: true, kids: [N(frame: full, kids: [left, right, dialog])])
    #expect(find(N(role: "AXWindow", frame: full, kids: [web])) == [r(263, 189, 551, 223), r(827, 189, 660, 223)])
}
