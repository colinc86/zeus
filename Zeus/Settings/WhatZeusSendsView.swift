import SwiftUI
import ZeusDesign

/// Settings › Privacy › "What Zeus sends your assistant" (PRIVACY.md §2.5, UX5): every kind Zeus sends, in the
/// ledger's words, each with its timing and its switch or a pointer to it. Reads settings; changes only the note kinds.
struct WhatZeusSendsView: View {
    @Bindable var settings: LearnSettings
    /// Level 1 ("Apps and timing") is on: the morning summary and the notes can go.
    var activityOn: Bool
    /// Any level is on: the evening reflection can go.
    var anyLevelOn: Bool
    /// The morning brief's effective state; nil where the brief has no setting (the standalone pane).
    var briefOn: Bool?
    /// Pointers to the other panes; nil in the standalone pane, where there is nowhere to go.
    var openAssistant: (@MainActor () -> Void)? = nil
    var openRules: (@MainActor () -> Void)? = nil

    static let title = "What Zeus sends your assistant"
    static let caption = "Each one goes to your assistant like a message, with private details removed first. The exact text is in What Zeus kept."
    static let summaryCaption = "Each morning, a short summary of the day before."
    static let notesCaption = "Up to four a day, when something changes:"
    static let reflectionCaption = "Each evening, a summary of the last 28 days: your rhythm, focus and recurring tasks, with private details removed."
    static let briefCaption = "At the start of your day, Zeus asks your assistant for one short brief of what matters today. It goes even when Learn from me is off."
    static let triggerCaption = "When one of your rules fires: the rule, what matched and the window."
    static let preferenceCaption = "When you rate a message: what you'd rather have, and nothing else."
    static let preferenceState = "Sent as you rate."
    static func summaryState(activityOn: Bool) -> String { activityOn ? "Sent while Apps and timing is on." : "Not sent: Apps and timing is off." }
    static func reflectionState(anyLevelOn: Bool) -> String { anyLevelOn ? "Sent while any level is on." : "Not sent: every level is off." }
    static func briefState(_ on: Bool) -> String { on ? "On." : "Off." }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title).settingsTitle()
            Text(Self.caption).settingsCaption()
            row("Morning summary", Self.summaryCaption, state: Self.summaryState(activityOn: activityOn))
            row("Notes", Self.notesCaption) {
                VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
                    ForEach(MomentKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(get: { settings.momentKinds.contains(kind) },
                                                         set: { if $0 { settings.momentKinds.insert(kind) } else { settings.momentKinds.remove(kind) } }))
                            .accessibilityLabel(kind.title)
                    }
                }
                .disabled(!activityOn)
            }
            row("Evening reflection", Self.reflectionCaption, state: Self.reflectionState(anyLevelOn: anyLevelOn))
            row("Morning brief request", Self.briefCaption, state: briefOn.map(Self.briefState)) {
                if let openAssistant {
                    KeyboardButton("Assistant Settings", action: openAssistant).accessibilityLabel("Assistant Settings, morning brief")
                }
            }
            row("Rule trigger", Self.triggerCaption) {
                if let openRules { KeyboardButton("Rules", action: openRules).accessibilityLabel("Open Rules") }
            }
            row("Message preference", Self.preferenceCaption, state: Self.preferenceState)
        }
    }

    /// One kind: its name, what it is, when it goes, then its switch or pointer. VoiceOver reads the three lines as one.
    private func row(_ title: String, _ caption: String, state: String? = nil,
                     @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
            Text(title).settingsBody()
                .accessibilityLabel([title + ".", caption, state].compactMap { $0 }.joined(separator: " "))
            Text(caption).settingsCaption().accessibilityHidden(true)
            HStack(spacing: ZeusTheme.Spacing.s) {
                if let state { Text(state).settingsCaption().accessibilityHidden(true) }
                trailing()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
