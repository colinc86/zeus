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
    var focusRequest: GeneralSettingsSection? = nil
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState(for: .voiceOver) private var focusedSection: GeneralSettingsSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpdateSettingsView(updater: updater).id(GeneralSettingsSection.updates)
                .accessibilityFocused($focusedSection, equals: .updates)
            SettingsDivider()
            Toggle("Let my assistant control Zeus", isOn: $settings.assistantMayControlApp)
                .accessibilityLabel("Let my assistant control Zeus")
            Toggle("Let my assistant install updates", isOn: $settings.assistantMayInstallUpdates)
                .accessibilityLabel("Let my assistant install updates")
                .disabled(!settings.assistantMayControlApp)
            Text(Self.assistantControlCaption).settingsCaption()
            SettingsDivider()
            Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                .accessibilityLabel("Show menu bar icon")
            Text(Self.menuBarIconCaption(hotKey: settings.talkHotKey)).settingsCaption()
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
            Text("Talk shortcut").settingsTitle().id(GeneralSettingsSection.shortcut)
                .accessibilityFocused($focusedSection, equals: .shortcut)
            Toggle("Enable global shortcut", isOn: Binding(get: { settings.talkHotKey.enabled }, set: { enabled in
                if enabled && !settings.talkHotKey.isValid { settings.talkHotKey = TalkHotKey() }
                else { settings.talkHotKey.enabled = enabled }
            }))
                .accessibilityLabel("Enable global shortcut")
            ZeusShortcutRecorder(settings: settings, hotKey: hotKey)
            Text(Self.shortcutCaption(settings.talkHotKey)).settingsCaption()
            if let error = hotKey.contextError { Text(error).settingsError() }
            SettingsDivider()
            Text("Sounds").settingsTitle().id(GeneralSettingsSection.sounds)
                .accessibilityFocused($focusedSection, equals: .sounds)
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
                Text("Conversation history").settingsTitle().id(GeneralSettingsSection.history)
                    .accessibilityFocused($focusedSection, equals: .history)
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
            .onChange(of: focusRequest) { focusedSection = focusRequest }
    }

    static func shortcutCaption(_ shortcut: TalkHotKey) -> String {
        guard shortcut.enabled, shortcut.isValid else { return "The shortcut is off. Click Zeus or use the menu to talk." }
        let base = "\(shortcut.displayName) opens Talk to Zeus from any app."
        if let context = shortcut.askAboutThis { return base + " Add ⇧ (\(context.displayName)) to ask about the window in front." }
        return base + " Ask About This is in the Zeus menu, because your shortcut already uses ⇧."
    }

    static let soundCaption = "Plays at your Mac's alert volume, set in System Settings → Sound. Zeus stays quiet while it's hidden, during quiet hours and while the conversation is open."
    /// MB1. The shortcut follows the user's Talk shortcut (⌥⌘Z by default) and is left out when it's off.
    static func menuBarIconCaption(hotKey: TalkHotKey) -> String {
        let base = "Right-click Zeus for the same menu. If Zeus is hidden and the icon is off, open Zeus again from Spotlight or Launchpad"
        guard hotKey.enabled, hotKey.isValid else { return base + "." }
        return base + ", or press " + hotKey.displayName + "."
    }
    static let assistantControlCaption = "Your assistant can change how Zeus looks and where it sits. Every change shows in the conversation with Undo. It can never answer its own questions or change its own settings."

    static func historyCaption(count: Int) -> String {
        "\(count) \(count == 1 ? "message" : "messages") saved on this Mac. \(ConversationHistoryCopy.preservation)"
    }
}

enum GeneralSettingsSection: String, CaseIterable {
    case updates = "Updates", sounds = "Sounds", shortcut = "Shortcut", history = "History"
}

/// Stays above the scroll view so every General section is discoverable at the minimum size.
struct GeneralSettingsJumpRow: View {
    let jump: (GeneralSettingsSection) -> Void
    @Environment(\.zeusPalette) private var palette
    @FocusState private var focused: GeneralSettingsSection?

    var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            ForEach(GeneralSettingsSection.allCases, id: \.self) { section in
                if section != .updates {
                    Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                }
                Button { jump(section) } label: {
                    Text(section.rawValue).frame(minHeight: 22).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused, equals: section)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(palette.focusRing).frame(height: ZeusTheme.pixel)
                            .opacity(focused == section ? 1 : 0).allowsHitTesting(false)
                    }
                    .accessibilityLabel("Jump to \(section.rawValue)")
                    .help(section.rawValue)
            }
        }
        .zeusFont(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("General sections")
    }
}
