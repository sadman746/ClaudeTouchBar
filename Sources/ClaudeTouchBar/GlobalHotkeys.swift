import Carbon.HIToolbox
import AppKit

/// Registers system-wide keyboard shortcuts using Carbon's RegisterEventHotKey —
/// still the standard mechanism for global hotkeys in AppKit apps, and unlike
/// NSEvent's global monitor it needs no Accessibility/Input Monitoring permission.
final class GlobalHotkeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x43544231 // 'CTB1'

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue().handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var hotKeyRef: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        hotKeyRefs.append(hotKeyRef)
    }
}
