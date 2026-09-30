import ApplicationServices
import FocusCore

/// Thin, checked AX readers. CF values come back as untyped `CFTypeRef`; every cast checks the
/// CF type id first, so a misbehaving app returning the wrong type yields nil instead of a crash.
extension AXUIElement {
    public func attribute(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }

    public func element(_ name: String) -> AXUIElement? {
        guard let v = attribute(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    public var frame: CGRect? {
        guard let p = attribute(kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    public var role: String? { attribute(kAXRoleAttribute) as? String }
    public var children: [AXUIElement] { attribute(kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    public var parent: AXUIElement? { element(kAXParentAttribute) }

    public var isFocusSettable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, kAXFocusedAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    public var pid: pid_t { var p: pid_t = 0; AXUIElementGetPid(self, &p); return p }
}

extension PaneTree where Node == AXUIElement {
    /// "Focusable" = the AXFocused attribute is settable (what the spike measured). Web dialogs are
    /// AXGroups told apart only by subrole, so the role reads the subrole for groups.
    public static var ax: PaneTree<AXUIElement> {
        PaneTree(role: { e in
            let r = e.role
            return r == "AXGroup" && e.attribute(kAXSubroleAttribute) as? String == "AXApplicationDialog" ? "AXApplicationDialog" : r
        }, frame: { $0.frame }, isFocusable: { $0.isFocusSettable }, children: { $0.children })
    }
}
