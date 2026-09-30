import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How to read one accessibility node. Closures (not a protocol) so FocusMac plugs in AXUIElement
/// and tests plug in plain structs.
public struct PaneTree<Node> {
    public var role: (Node) -> String?
    public var frame: (Node) -> CGRect?
    public var isFocusable: (Node) -> Bool
    public var children: (Node) -> [Node]

    public init(role: @escaping (Node) -> String?, frame: @escaping (Node) -> CGRect?,
                isFocusable: @escaping (Node) -> Bool, children: @escaping (Node) -> [Node]) {
        self.role = role; self.frame = frame; self.isFocusable = isFocusable; self.children = children
    }
}

/// Finds the split panes of a window (rule from docs/spikes/ax-panes.md).
///
/// A pane is a focusable node whose *visible* rect is at least `minSize` and that has no focusable
/// descendant of that size. "Deepest" matters: Electron apps wrap each pane in a chain of
/// window-sized focusable groups. When the window contains an `AXWebArea` (Electron/web content),
/// only panes inside it count; native apps are searched from the window.
///
/// Visible rect = the node's frame clipped by every ancestor's frame, because a text area is as tall
/// as its document while only its scroll area shows. Subtrees whose visible rect is smaller than
/// `minSize` are skipped: their children cannot be bigger, and web content has thousands of tiny
/// nodes, each costing an AX round trip.
public enum PaneFinder {
    public static func panes<Node>(in window: Node, windowFrame: CGRect, minSize: CGSize,
                                   maxNodes: Int = 3000, tree: PaneTree<Node>) -> [(node: Node, frame: CGRect)] {
        typealias Pane = (node: Node, frame: CGRect)
        // ponytail: fixed node budget; a pathological tree yields partial panes. Raise it if a real
        // app's panes go missing in `ax-dump`.
        var budget = maxNodes

        func walk(_ n: Node, clip: CGRect, inWeb: Bool, depth: Int) -> (panes: [Pane], web: Bool) {
            // Spend the budget before any AX round trip (frame/role/children/isFocusable): once
            // it is gone, every remaining sibling must cost nothing, not one more `frame` read.
            budget -= 1
            guard budget >= 0, depth < 60 else { return ([], false) }
            let visible = tree.frame(n).map { $0.intersection(clip) } ?? clip
            guard !visible.isNull, visible.width >= minSize.width, visible.height >= minSize.height
            else { return ([], false) }
            let role = tree.role(n)
            // A dialog floats over the panes (Xirp's update popup: AXGroup/AXApplicationDialog over
            // both terminals). Counted as a pane it overlaps its neighbours, so no pane click is ever
            // safe while it is up, and it is never somewhere the user wants to type.
            if role == "AXApplicationDialog" { return ([], false) }
            let isWeb = !inWeb && role == "AXWebArea"
            var found: [Pane] = []
            for child in tree.children(n) {
                guard budget >= 0 else { break }   // stop descending the moment the budget is spent
                let sub = walk(child, clip: visible, inWeb: inWeb || isWeb, depth: depth + 1)
                if sub.web { return sub }          // web content wins over surrounding native chrome
                found += sub.panes
            }
            if found.isEmpty, tree.isFocusable(n) { found = [(n, visible)] }
            return (found, isWeb)
        }

        var out: [Pane] = []
        for p in walk(window, clip: windowFrame, inWeb: false, depth: 0).panes
        where !out.contains(where: { $0.frame == p.frame }) { out.append(p) }
        return out.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }
}
