import SwiftUI
import Observation
import ZeusProtocol
import ZeusDesign

enum SettingsTab: String, CaseIterable {
    case general = "General", appearance = "Appearance", agent = "Assistant", character = "Character", about = "About"
    #if DEBUG
    case debug = "Debug"
    #endif
}

@MainActor
@Observable
final class SettingsNavigation { var tab = SettingsTab.general }

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let managed: ManagedAssistantModel
    let cards: CardStore
    let status: AvatarStatusModel
    let messaging: any AgentMessaging
    let preview: AgentMessagingHub
    let testMessage: ComposeModel
    let injectDemo: (DemoCardKind) -> Void
    let resetPosition: () -> Void
    @Bindable var navigation: SettingsNavigation
    let login: LoginItemModel
    let hotKey: GlobalHotKey
    let activity: SurfaceActivity
    var updater: any AppUpdating = UpdaterService()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// This root's own colors come from the theme directly: the environment it sets applies to its children.
    private var palette: ZeusPalette { settings.currentTheme.palette(for: colorScheme, contrast: colorSchemeContrast) }

    // T1: the selected theme reaches every view below through \.zeusTheme (and so \.zeusPalette).
    var body: some View { rootBody.environment(\.zeusTheme, settings.currentTheme) }

    @ViewBuilder private var rootBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsTabBar(navigation: navigation)
            Rectangle().fill(palette.fieldBorder).frame(height: ZeusTheme.pixel)
            ScrollViewReader { proxy in
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .leading)
                        // One type system (D2-3): Zeus buttons, checkboxes, fields and body text unless a pane says otherwise.
                        .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                        .toggleStyle(ZeusCheckboxStyle())
                        .textFieldStyle(ZeusTextFieldStyle())
                        .settingsBody()
                }
                .onChange(of: managed.confirmation, initial: true) { revealManagedConfirmation(proxy) }
                .onChange(of: navigation.tab) { revealManagedConfirmation(proxy) }
            }
        }
        .padding(24).frame(width: 572, height: 572)
        .environment(\.zeusAnimationsActive, activity.settings)
        .environment(\.zeusFontChoice, .system)
        // UI scripting can query Settings without activating VoiceOver first.
        .environment(\.accessibilityEnabled, true)
    }

    private func revealManagedConfirmation(_ proxy: ScrollViewProxy) {
        guard navigation.tab == .agent, managed.confirmation == .newConversation else { return }
        Task { @MainActor in
            await Task.yield()
            guard navigation.tab == .agent, managed.confirmation == .newConversation else { return }
            proxy.scrollTo("newConversationConfirmation", anchor: .top)
        }
    }

    @ViewBuilder private var content: some View {
        switch navigation.tab {
        case .general:
            GeneralSettingsView(settings: settings, login: login, hotKey: hotKey, cards: cards, updater: updater)
        case .appearance:
            AppearanceSettingsView(settings: settings)
        case .agent:
            AssistantSettingsView(settings: settings, managed: managed, messaging: preview, testMessage: testMessage)
        case .character:
            CharacterSettingsView(settings: settings, resetPosition: resetPosition)
        case .about:
            AboutSettingsView()
        #if DEBUG
        case .debug:
            VStack(alignment: .leading, spacing: 16) {
                Text("Messaging preview").zeusFont(.title)
                Toggle("Use preview sessions and simulated sends", isOn: Binding(get: { preview.previewEnabled }, set: { preview.previewEnabled = $0 })).accessibilityLabel("Use preview sessions and simulated sends")
                Picker("Preview result", selection: Binding(get: { preview.previewOutcome }, set: { preview.previewOutcome = $0 })) {
                    ForEach(AgentMessagingHub.PreviewOutcome.allCases) { outcome in Text(outcome.rawValue.capitalized).tag(outcome) }
                }.disabled(!preview.previewEnabled)
                Text("Preview sends stay in this app and never reach an agent.").settingsCaption()
                Picker("Assistant activity", selection: Binding(get: { preview.previewActivity }, set: { preview.previewActivity = $0 })) {
                    ForEach(AgentMessagingHub.PreviewActivity.allCases) { phase in Text(phase.rawValue.capitalized).tag(phase) }
                }.disabled(!preview.previewEnabled)
                if preview.previewActivity == .working {
                    ZeusTextField("Activity detail", text: Binding(get: { preview.previewActivityDetail }, set: { preview.previewActivityDetail = $0 }))
                    Toggle("Show progress", isOn: Binding(get: { preview.previewActivityProgress != nil }, set: { preview.previewActivityProgress = $0 ? 0.4 : nil })).accessibilityLabel("Show progress")
                    if preview.previewActivityProgress != nil {
                        Slider(value: Binding(get: { preview.previewActivityProgress ?? 0 }, set: { preview.previewActivityProgress = $0 }), in: 0...1)
                    }
                }
                SettingsDivider()
                Text("Demo cards").zeusFont(.title)
                ForEach(DemoCardKind.allCases) { kind in Button(kind.rawValue) { injectDemo(kind) }.accessibilityLabel(kind.rawValue) }
                Text("Replies are recorded in card history. Delivery starts when the runtime is connected.")
                    .settingsCaption()
                if let last = cards.history.first(where: { $0.response != nil }) {
                    Text("Last reply: \(last.response?.summary ?? "")").settingsCaption()
                }
                SettingsDivider()
                Text("Avatar state").settingsHeading()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                    ForEach(AvatarState.allCases, id: \.self) { state in
                        Button(state.rawValue.capitalized) { status.setOverride(state, detail: "Debug preview", progress: state == .working ? 0.45 : nil, ttl: 600) }.accessibilityLabel(state.rawValue.capitalized)
                    }
                }
                Button("Automatic state") { status.clearOverride() }.accessibilityLabel("Automatic state")
                Text("New cards take priority for 2.5 seconds.").settingsCaption()
                Button(preview.previewDeliveryIssue == nil ? "Show preview delivery warning" : "Clear preview delivery warning") {
                    preview.previewDeliveryIssue = preview.previewDeliveryIssue == nil
                        ? DeliveryIssue(title: "Couldn't reach your assistant", detail: "2 replies couldn't reach Preview Claude (Zeus). They'll be sent automatically when it reconnects.", pendingCount: 2, since: Date().addingTimeInterval(-180)) : nil
                }.accessibilityLabel(preview.previewDeliveryIssue == nil ? "Show preview delivery warning" : "Clear preview delivery warning").disabled(!preview.previewEnabled)
                if let error = cards.persistenceError { Text(error).foregroundStyle(palette.destructive) }
            }
        #endif
        }
    }

}

/// Keeps the Settings navigation controls named independently of the selected pane.
struct SettingsTabBar: View {
    @Bindable var navigation: SettingsNavigation
    var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button { navigation.tab = tab } label: {
                    Text(tab.rawValue).frame(maxWidth: .infinity)
                }
                .buttonStyle(ZeusButtonStyle(navigation.tab == tab ? .primary : .secondary, size: .small))
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(navigation.tab == tab ? [.isSelected] : [])
            }
        }
    }
}
