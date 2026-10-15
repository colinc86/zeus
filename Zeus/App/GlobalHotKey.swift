import Carbon
import Observation

/// Registers only the chosen shortcut and forwards its Carbon event to the main-actor app.
@MainActor
@Observable
final class GlobalHotKey {
    private(set) var error: String?
    private(set) var contextError: String?
    @ObservationIgnored var onPressed: (() -> Void)?
    @ObservationIgnored var onAskAboutThis: (() -> Void)?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var contextHotKey: EventHotKeyRef?
    private(set) var isContextRegistered = false
    @ObservationIgnored private var configured: TalkHotKey?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var stopped = false
    var isRegistered: Bool { hotKey != nil }
    @ObservationIgnored private var handler: EventHandlerRef?
    private nonisolated static let signature: OSType = 0x5A455553 // ZEUS

    /// Explicit app startup is the only path that can reactivate a stopped registrar.
    func start(_ shortcut: TalkHotKey) { stopped = false; configure(shortcut) }

    func configure(_ shortcut: TalkHotKey) {
        guard !stopped else { return }
        if configured == shortcut, hotKey != nil, !suspended { return }
        unregister()
        configured = shortcut
        error = nil; contextError = nil
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
        if status != noErr { error = "That shortcut is taken by another app."; return }
        if let context = shortcut.askAboutThis {
            let contextID = EventHotKeyID(signature: Self.signature, id: 2)
            let result = RegisterEventHotKey(context.keyCode, context.modifiers, contextID, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &contextHotKey)
            isContextRegistered = result == noErr
            if result != noErr { contextError = "The Ask About This shortcut is taken by another app. Use the Zeus menu." }
        }
    }

    func suspend() { guard !stopped else { return }; suspended = true; error = nil; contextError = nil; unregister() }
    func resume(_ shortcut: TalkHotKey) { guard !stopped else { return }; suspended = false; configure(shortcut) }
    private func unregister() {
        isContextRegistered = false
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let contextHotKey { UnregisterEventHotKey(contextHotKey); self.contextHotKey = nil }
    }

    func stop() {
        stopped = true; suspended = false; configured = nil; error = nil; contextError = nil
        unregister()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        onPressed = nil; onAskAboutThis = nil
    }

    private nonisolated static let receive: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == signature, (id.id == 1 || id.id == 2) else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        let isContext = id.id == 2
        Task { @MainActor [weak controller] in
            guard let controller, !controller.suspended, !controller.stopped else { return }
            if isContext, controller.contextHotKey != nil { controller.onAskAboutThis?() }
            else if !isContext, controller.hotKey != nil { controller.onPressed?() }
        }
        return noErr
    }
}
