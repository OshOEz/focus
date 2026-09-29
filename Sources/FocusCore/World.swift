import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct DisplayInfo: Sendable {
    public var key: String
    public var frame: CGRect
    public init(key: String, frame: CGRect) { self.key = key; self.frame = frame }
}

public struct WindowInfo: Sendable, Equatable {
    public var id: UInt32
    public var frame: CGRect
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
}

/// Snapshot of the desktop, built by FocusMac each frame. Global CG coordinates.
public struct World: Sendable {
    public var displays: [DisplayInfo]
    public var windows: [WindowInfo]       // front to back
    public var focusedWindowID: UInt32?
    public var panes: [CGRect]              // panes of the focused window
    public var focusedPane: Int?

    public init(displays: [DisplayInfo], windows: [WindowInfo], focusedWindowID: UInt32?,
                panes: [CGRect] = [], focusedPane: Int? = nil) {
        self.displays = displays; self.windows = windows; self.focusedWindowID = focusedWindowID
        self.panes = panes; self.focusedPane = focusedPane
    }
}

public enum FocusAction: Equatable, Sendable {
    case display(String)
    case window(UInt32)
    case pane(window: UInt32, frame: CGRect)
}

func globalPoint(_ p: CGPoint, in f: CGRect) -> CGPoint {
    CGPoint(x: f.minX + p.x * f.width, y: f.minY + p.y * f.height)
}

func localPoint(_ p: CGPoint, in f: CGRect) -> CGPoint {
    CGPoint(x: (p.x - f.minX) / f.width, y: (p.y - f.minY) / f.height)
}
