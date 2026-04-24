import Carbon.HIToolbox
import Foundation

final class GlobalHotkey {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        installEventHandler()
    }

    func register(keyCode: UInt32, modifiers: UInt32, onFire: @escaping @MainActor () -> Void) {
        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: fourCharCode("RTIH"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            NSLog("[RTI] RegisterEventHotKey failed for id=\(id), status=\(status)")
            return
        }
        refs[id] = ref
        handlers[id] = onFire
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        // Unretained: AppDelegate holds the only strong ref to this instance for the app's lifetime.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }
                let manager = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                if let handler = manager.handlers[hotKeyID.id] {
                    Task { @MainActor in handler() }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}

private func fourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for (i, scalar) in string.unicodeScalars.prefix(4).enumerated() {
        result |= UInt32(scalar.value) << (24 - i * 8)
    }
    return result
}
