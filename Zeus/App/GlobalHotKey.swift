import Carbon
import Observation

/// Registers only the chosen shortcut and forwards its Carbon event to the main-actor app.
@MainActor
@Observable
final class GlobalHotKey {
    private(set) var error: String?
    @ObservationIgnored var onPressed: (() -> Void)?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var configured: TalkHotKey?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var handler: EventHandlerRef?
    private nonisolated static let signature: OSType = 0x5A455553 // ZEUS

    func configure(_ shortcut: TalkHotKey) {
        if configured == shortcut, hotKey != nil, !suspended { return }
        unregister()
        configured = shortcut
        error = nil
        guard !suspended else { return }
        guard shortcut.enabled else { return }
        guard shortcut.isValid else {
            error = shortcut.validationError
            return
        }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), Self.receive, 1, &type,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { error = "Could not enable the Talk shortcut (\(status))."; return }
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &hotKey)
        if status != noErr { error = "That shortcut is taken by another app." }
    }

    func suspend() { suspended = true; error = nil; unregister() }
    func resume(_ shortcut: TalkHotKey) { suspended = false; configure(shortcut) }
    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
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
        Task { @MainActor [weak controller] in if let controller, !controller.suspended, controller.hotKey != nil { controller.onPressed?() } }
        return noErr
    }
}
