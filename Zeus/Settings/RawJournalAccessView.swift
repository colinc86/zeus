import Observation
import SwiftUI
import ZeusDesign

@MainActor @Observable
final class RawJournalConsentModel {
    let settings: ObservationSettings
    let level: JournalLevel
    var showsConsent = false
    init(settings: ObservationSettings, level: JournalLevel) { self.settings = settings; self.level = level }
    func setEnabled(_ enabled: Bool) {
        guard [.screen, .typed].contains(level) else { return }
        if enabled { showsConsent = true }
        else { showsConsent = false; settings.setRawAllowed(false, level: level.rawValue) }
    }
    func allow() {
        guard showsConsent else { return }
        settings.setRawAllowed(true, level: level.rawValue); showsConsent = false
    }
    func cancel() { showsConsent = false }
}

/// Raw access is separate from local capture consent; only Allow persists a new grant.
struct RawJournalAccessView: View {
    @Bindable var settings: ObservationSettings
    let level: JournalLevel
    @State private var consent: RawJournalConsentModel
    init(settings: ObservationSettings, level: JournalLevel) {
        self.settings = settings; self.level = level
        _consent = State(initialValue: RawJournalConsentModel(settings: settings, level: level))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(RawJournalCopy.label(level), isOn: Binding(get: { settings.rawAllowed(level.rawValue) }, set: consent.setEnabled)).accessibilityLabel(RawJournalCopy.label(level))
            Text(RawJournalCopy.caption(level)).settingsCaption()
        }.sheet(isPresented: $consent.showsConsent) {
            RawJournalConsentSheet(level: level, allow: {
                consent.allow()
            }, cancel: { consent.cancel() })
        }
    }
}

enum RawJournalCopy {
    static func label(_ level: JournalLevel) -> String {
        level == .screen ? "Let my assistant see the pictures when it asks" : "Let my assistant see the words when it asks"
    }
    static func caption(_ level: JournalLevel) -> String {
        "Otherwise it gets only \(level == .screen ? "descriptions" : "topics"). Each time it looks, you'll see a line in the conversation."
    }
    static func body(_ level: JournalLevel) -> String {
        level == .screen
            ? "When your assistant asks about a moment, it can get the picture Zeus kept (with private text covered and pictures pixellated), not just the description. That picture goes to your assistant's model provider, like anything you send."
            : "When your assistant asks about a moment, it can get the words Zeus kept (with names, numbers and secrets removed), not just the topic. Those words go to your assistant's model provider, like anything you send."
    }
}

struct RawJournalConsentSheet: View {
    let level: JournalLevel
    let allow: @MainActor @Sendable () -> Void
    let cancel: @MainActor @Sendable () -> Void
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(level == .screen ? "Let your assistant see pictures?" : "Let your assistant see the words?").settingsTitle()
            Text(RawJournalCopy.body(level)).settingsBody()
            Text("Every time it looks, the conversation says so, and What Zeus Kept › Sent to your assistant shows exactly what it got.").settingsCaption()
            HStack {
                Spacer()
                KeyboardButton("Cancel", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel raw journal access")
                KeyboardButton("Allow", action: allow).buttonStyle(ZeusButtonStyle(.primary, size: .small)).accessibilityLabel("Allow \(level == .screen ? "pictures" : "words") when requested")
            }
        }.padding(24).frame(width: 520).fixedSize(horizontal: false, vertical: true)
            .environment(\.zeusFontChoice, .system).onAppear { cancelFocused = true }
    }
}
