import Carbon
import ClamCore

/// Carbon registration avoids an event tap / Accessibility permission request.
/// Availability at a locked/login session is not guaranteed by macOS.
final class RecoveryHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static let signature: OSType = 0x434C414D // CLAM

    init(action: @escaping () -> Void) { self.action = action }

    func register() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == RecoveryHotKey.signature, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<RecoveryHotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else {
            RecoveryDiagnostics.record("hotkey handler registration failed: \(result)")
            return false
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey),
                                            id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            RecoveryDiagnostics.record("hotkey registration failed: \(registered)")
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    deinit { unregister() }
}
