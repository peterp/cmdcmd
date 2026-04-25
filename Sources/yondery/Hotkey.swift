import AppKit
import Carbon.HIToolbox

let cmdShift: UInt32 = UInt32(cmdKey | shiftKey)

final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let hk = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            hk.handler()
            _ = eventRef
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x594F4E44), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
