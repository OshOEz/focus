import AppKit
import CoreGraphics
import FocusCore

/// Connected screens in global CG coordinates (top-left origin, same space as windows and AX),
/// keyed by stable fingerprints made unique within the set.
@MainActor public final class DisplayProvider {
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var fingerprints: [DisplayFingerprint] = []
    /// Fires on the main thread when the set or arrangement of screens really changed.
    public var onChange: (() -> Void)?
    private var ids: [String: CGDirectDisplayID] = [:]

    public init() {
        refresh()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    public func refresh() {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &list, &n)
        // A mirror shows another display's pixels: one screen to look at, one calibration.
        let shown = list.prefix(Int(n)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let fps = shown.map { id -> DisplayFingerprint in
            let b = CGDisplayBounds(id)
            return DisplayFingerprint(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                      serial: CGDisplaySerialNumber(id), width: Int(b.width), height: Int(b.height),
                                      originX: Int(b.minX), originY: Int(b.minY))
        }
        let keys = DisplayFingerprint.uniqueKeys(fps)
        let changed = fps != fingerprints
        fingerprints = fps
        displays = zip(keys, shown).map { DisplayInfo(key: $0, frame: CGDisplayBounds($1)) }
        ids = Dictionary(uniqueKeysWithValues: zip(keys, shown))
        if changed { onChange?() }
    }

    /// The user-facing name ("Studio Display", "Built-in Retina Display").
    public func name(for key: String) -> String { screen(for: key)?.localizedName ?? "Display" }

    /// For windows placed on a display (calibration, gaze dot).
    public func screen(for key: String) -> NSScreen? {
        guard let id = ids[key] else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}

/// CoreGraphics calls this once per display per change, after a "begin" pass. Only completion
/// passes matter and `refresh()` coalesces them (onChange fires only on a real difference).
// ponytail: raw pointer to a provider that lives as long as the app; unregister before freeing it in any other use.
private let displayReconfigured: CGDisplayReconfigurationCallBack = { _, flags, info in
    guard !flags.contains(.beginConfigurationFlag), let info else { return }
    let address = UInt(bitPattern: info)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            Unmanaged<DisplayProvider>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue().refresh()
        }
    }
}
