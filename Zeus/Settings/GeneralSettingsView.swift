import SwiftUI
import ZeusDesign

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    let login: LoginItemModel
    let hotKey: GlobalHotKey
    var cards: CardStore? = nil
    var updater: any AppUpdating = UpdaterService()
    /// Previews a pop-up sound when it's chosen or turned on.
    var preview: (PopupSound) -> Void = { SystemPopupSoundPlayer.shared.play($0) }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpdateSettingsView(updater: updater)
            SettingsDivider()
            Text("Appearance").settingsTitle()
            SettingsSegments(label: "Conversation font", options: ZeusFontChoice.allCases.map { ($0, $0.displayName) }, selection: $settings.fontChoice)
            SettingsDivider()
            Toggle("Launch Zeus at login", isOn: Binding(get: { login.enabled }, set: { value in Task { await login.setEnabled(value) } }))
                .accessibilityLabel("Launch Zeus at login")
                .disabled(login.isUpdating)
            if login.status == .requiresApproval {
                Text("Allow Zeus in System Settings → Login Items to launch at login.").settingsCaption()
                Button("Open Login Items") { login.openLoginSettings() }.accessibilityLabel("Open Login Items")
            }
            if let error = login.error { Text(error).settingsError() }
            SettingsDivider()
            Text("Talk shortcut").settingsTitle()
            Toggle("Enable global shortcut", isOn: $settings.talkHotKey.enabled)
                .accessibilityLabel("Enable global shortcut")
            HStack {
                Picker("Key", selection: $settings.talkHotKey.key) { ForEach(TalkHotKey.letters, id: \.self) { Text($0).tag($0) } }
                Toggle("Control", isOn: $settings.talkHotKey.control)
                    .accessibilityLabel("Control")
                Toggle("Option", isOn: $settings.talkHotKey.option)
                    .accessibilityLabel("Option")
                Toggle("Shift", isOn: $settings.talkHotKey.shift)
                    .accessibilityLabel("Shift")
                Toggle("Command", isOn: $settings.talkHotKey.command)
                    .accessibilityLabel("Command")
            }.disabled(!settings.talkHotKey.enabled)
            Text("\(settings.talkHotKey.displayName) opens Talk to Zeus from any app.").settingsCaption()
            if let error = hotKey.error { Text(error).settingsError() }
            Button("Reset Shortcut") { settings.talkHotKey = TalkHotKey() }.accessibilityLabel("Reset Shortcut")
            SettingsDivider()
            Text("Sounds").settingsTitle()
            Toggle("Play a sound when Zeus pops up", isOn: Binding(get: { settings.popupSoundEnabled }, set: { on in
                settings.popupSoundEnabled = on
                if on { preview(settings.popupSound) }
            }))
            .accessibilityLabel("Play a sound when Zeus pops up")
            Picker("Sound", selection: Binding(get: { settings.popupSound }, set: { sound in
                settings.popupSound = sound
                preview(sound)
            })) { ForEach(PopupSound.allCases) { Text($0.title).tag($0) } }
            .accessibilityLabel("Pop-up sound")
            .disabled(!settings.popupSoundEnabled)
            Text(Self.soundCaption).settingsCaption()
            SettingsDivider()
            Text("Message reveal").settingsTitle()
            Toggle("Typewriter reveal", isOn: $settings.typewriterEnabled)
                .accessibilityLabel("Typewriter reveal")
            Toggle("Retro blip sound", isOn: $settings.soundEnabled).disabled(!settings.typewriterEnabled)
                .accessibilityLabel("Retro blip sound")
            Text("Click a message that's typing to show it all at once. Reduce Motion turns both off, and the sound stays quiet during quiet hours.").settingsCaption()
            if let cards {
                SettingsDivider()
                Text("Conversation history").settingsTitle()
                Text(Self.historyCaption(count: cards.cards.count)).settingsCaption()
                ClearConversationButton(cards: cards)
                if let error = cards.persistenceError {
                    Text(error).settingsError().textSelection(.enabled)
                    Button("Retry Saving History") { _ = cards.retryPersistence() }.accessibilityLabel("Retry Saving History")
                }
            }
        }
            .onAppear { login.refresh() }
            .onChange(of: scenePhase) { if scenePhase == .active { login.refresh() } }
    }

    static let soundCaption = "Plays at your Mac's alert volume, set in System Settings → Sound. Zeus stays quiet while it's hidden, during quiet hours and while the conversation is open."

    static func historyCaption(count: Int) -> String {
        "\(count) \(count == 1 ? "message" : "messages") saved on this Mac. \(ConversationHistoryCopy.preservation)"
    }
}
