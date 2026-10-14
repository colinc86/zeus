import Carbon
import Observation

/// Registers only the chosen shortcut and forwards its Carbon event to the main-actor app.
@MainActor
@Observable
final class GlobalHotKey {
    private(set) var error: String?
    @ObservationIgnored var onPressed: (() -> Void)?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    private nonisolated static let signature: OSType = 0x5A455553 // ZEUS

    func configure(_ shortcut: TalkHotKey) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        error = nil
        guard shortcut.enabled else { return }
        guard shortcut.isValid, let code = shortcut.keyCode else {
            error = "Choose a letter and at least one of Command, Option or Control."
            return
        }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), Self.receive, 1, &type,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { error = "Could not enable the Talk shortcut (\(status))."; return }
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(code, shortcut.modifiers, id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &hotKey)
        if status != noErr { error = "That shortcut is unavailable. Choose another combination (\(status))." }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        onPressed = nil
    }

    private nonisolated static let receive: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor [weak controller] in controller?.onPressed?() }
        return noErr
    }
}
