import AppKit
import Carbon
import Observation
import SwiftUI
import ZeusDesign

@MainActor protocol ShortcutRegistering: AnyObject {
    var error: String? { get }
    func suspend()
    func resume(_ shortcut: TalkHotKey)
}
extension GlobalHotKey: ShortcutRegistering {}

/// Keeps persistence behind successful registration, and owns only a window-local recording monitor.
@MainActor @Observable final class ShortcutRecorderModel {
    private(set) var isRecording = false
    private(set) var error: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var announce: (String) -> Void = { _ in }
    @ObservationIgnored private let registration: any ShortcutRegistering
    @ObservationIgnored private let current: () -> TalkHotKey
    @ObservationIgnored private let save: (TalkHotKey) -> Void
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    init(registration: any ShortcutRegistering, current: @escaping () -> TalkHotKey, save: @escaping (TalkHotKey) -> Void) {
        self.registration = registration; self.current = current; self.save = save
    }
    func start() {
        guard !isRecording else { return }
        error = nil; isRecording = true; registration.suspend(); announce("Recording")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isRecording else { return false }
                guard let window = self.window, event.window === window else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        }
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        guard !event.isARepeat else { return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty {
            if event.keyCode == kVK_Escape { cancel(); return true }
            if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete { clear(); return true }
            if event.keyCode == kVK_Tab { cancel(); return false }
        }
        finish(TalkHotKey(event: event)); return true
    }
    func cancel() {
        guard isRecording else { return }
        endCapture(); registration.resume(current()); announce("Recording cancelled. " + value)
    }
    func clear() { var cleared = current(); cleared.keyCode = UInt32.max; cleared.enabled = false; finish(cleared) }
    func reset() { finish(TalkHotKey()) }
    var value: String { current().keyCode == UInt32.max ? "None" : current().displayName }
    private func finish(_ candidate: TalkHotKey) {
        endCapture()
        if candidate.enabled, let reason = candidate.validationError {
            error = reason; registration.resume(current()); announce(reason); return
        }
        registration.resume(candidate)
        if let reason = registration.error {
            error = reason; registration.resume(current()); announce(reason); return
        }
        save(candidate); error = nil; announce(value)
    }
    private func endCapture() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }
}

/// Zeus field chrome with native keyboard focus and a local capture, without Accessibility permission.
struct ZeusShortcutRecorder: View {
    let settings: AppSettings
    let hotKey: GlobalHotKey
    @State private var recorder: ShortcutRecorderModel
    @State private var focused = false
    @State private var pulse = false
    @Environment(\.zeusPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(settings: AppSettings, hotKey: GlobalHotKey, recorder: ShortcutRecorderModel? = nil) {
        self.settings = settings; self.hotKey = hotKey
        _recorder = State(initialValue: recorder ?? ShortcutRecorderModel(registration: hotKey, current: { settings.talkHotKey }, save: { settings.talkHotKey = $0 }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
            HStack(spacing: ZeusTheme.Spacing.s) {
                Text("Talk to Zeus").settingsBody()
                ZStack {
                    ZeusFieldChrome(isFocused: focused && settings.talkHotKey.enabled && !recorder.isRecording) {
                        Text(recorder.isRecording ? "Type a shortcut…" : recorder.value)
                            .foregroundStyle(recorder.isRecording || !settings.talkHotKey.enabled ? palette.secondaryText : palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityHidden(true)
                    if recorder.isRecording {
                        PixelRoundedRectangle(steps: 1).stroke(palette.focusRing, lineWidth: ZeusTheme.pixel)
                            .padding(ZeusTheme.pixel * 1.5)
                            .opacity(pulse && !reduceMotion ? 0.5 : 1).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    ShortcutCapture(recorder: recorder, enabled: settings.talkHotKey.enabled, focused: $focused)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 180)
                KeyboardButton(action: { recorder.reset() }, label: { Text("↺").frame(minWidth: 22, minHeight: 22) })
                    .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
                    .opacity(!settings.talkHotKey.enabled || settings.talkHotKey == TalkHotKey() ? 0.5 : 1)
                    .help("Reset to ⌥⌘Z").accessibilityLabel("Reset to Option-Command-Z")
                    .disabled(!settings.talkHotKey.enabled || settings.talkHotKey == TalkHotKey())
            }
            if !recorder.isRecording, let error = recorder.error ?? hotKey.error { Text(error).settingsError() }
        }
        .environment(\.zeusFontChoice, .system)
        .task(id: recorder.isRecording && !reduceMotion) {
            pulse = false
            guard recorder.isRecording, !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1)) { pulse.toggle() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onDisappear { recorder.cancel() }
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    let recorder: ShortcutRecorderModel
    let enabled: Bool
    @Binding var focused: Bool
    func makeNSView(context: Context) -> Field { Field() }
    func updateNSView(_ field: Field, context: Context) {
        field.recorder = recorder; field.isEnabled = enabled
        field.focusChanged = { focused = $0 }
        field.setAccessibilityValue(recorder.isRecording ? "Recording" : recorder.value)
        field.setAccessibilityEnabled(enabled)
        recorder.window = field.window
        recorder.announce = { [weak field] text in
            guard let field else { return }
            NSAccessibility.post(element: field, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    static func dismantleNSView(_ field: Field, coordinator: ()) { field.recorder?.cancel() }
    @MainActor final class Field: NSControl {
        weak var recorder: ShortcutRecorderModel?
        var focusChanged: (Bool) -> Void = { _ in }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.button)
            setAccessibilityLabel("Talk to Zeus shortcut")
            setAccessibilityHelp("Press Space or Return to record a shortcut. Escape cancels. Delete clears.")
            focusRingType = .none
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { isEnabled }
        override func becomeFirstResponder() -> Bool { focusChanged(true); return true }
        override func resignFirstResponder() -> Bool { focusChanged(false); recorder?.cancel(); return true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); recorder?.window = window; if window == nil { recorder?.cancel() } }
        override func mouseDown(with event: NSEvent) { _ = accessibilityPerformPress() }
        override func keyDown(with event: NSEvent) {
            if isEnabled && (event.keyCode == kVK_Space || event.keyCode == kVK_Return) { recorder?.start() }
            else { super.keyDown(with: event) }
        }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            window?.makeFirstResponder(self); recorder?.start(); return true
        }
    }
}
