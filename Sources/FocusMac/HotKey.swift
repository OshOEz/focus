import AppKit
import Carbon

/// A system-wide shortcut through Carbon's RegisterEventHotKey: the one API that needs no
/// permission and doesn't see other keystrokes. Events arrive through the app's main event
/// loop, so the action runs on the main thread. Rebinding = drop this instance, create another.
public final class HotKey {
    private let action: () -> Void
    private let id = UInt32.random(in: 1...UInt32.max)
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// nil when the combination is invalid (see `isValid`) or already taken by another app.
    public init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        guard Self.isValid(modifiers: modifiers) else { return nil }
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKey>.fromOpaque(user!).takeUnretainedValue()
            guard hk.id == me.id else { return OSStatus(eventNotHandledErr) }   // another HotKey's
            me.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return nil }
        let signature: OSType = 0x4643_5553   // 'FCUS'
        guard RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: id),
                                  GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil   // fully initialized: deinit removes the handler
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Must include ⌘, ⌃ or ⌥: a bare or ⇧-only key would fire while typing.
    public static func isValid(modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    /// For the shortcut recorder (NSEvent → Carbon mask); caps lock and fn are ignored.
    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return UInt32(m)
    }
}
