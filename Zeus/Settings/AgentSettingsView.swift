import AppKit
import SwiftUI
import ZeusDesign

struct AgentSettingsView: View {
    @Bindable var settings: AppSettings
    let messaging: any AgentMessaging
    let testMessage: ComposeModel
    @State private var password = ""
    @State private var passwordSaved = false
    @State private var discovery = TmuxPaneDiscovery()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let hub = messaging as? AgentMessagingHub { AgentLinkStatusView(hub: hub) }
            Text("Your assistant").settingsTitle()
            SettingsSegments(label: "Agent", options: AssistantBackend.allCases.map { ($0, $0.name) }, selection: $settings.backend)
            Text("How Zeus reaches it").settingsHeading()
            ZeusChoiceList(DeliveryMethod.allCases.map { ZeusChoice(id: $0, title: $0.displayName, detail: $0.detail) },
                selection: Binding(get: { settings.deliveryMethod }, set: { if let method = $0 { settings.deliveryMethod = method } }))
            AssistantSessionPicker(settings: settings, sessions: messaging.sessions)
            if let notice = settings.assistantSessionNotice {
                Text(notice).settingsCaption().lineLimit(1).help(notice)
            }
            if messaging.sessions.isEmpty { Text("No sessions yet. Follow the steps below, then start your agent.").settingsCaption() }
            ForEach(uniqueSessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.sessionLabels.label(session.sessionKey)).settingsBody().lineLimit(1).truncationMode(.middle).help(SessionLabels.label(for: session))
                    Text(SessionLabels.processCaption(for: session)).lineLimit(1).help(SessionLabels.processCaption(for: session))
                }.settingsCaption()
            }
            if settings.deliveryMethod == .tmux {
                HStack {
                    let panes = discovery.panes
                    let socket = settings.tmuxTargetSocketPath ?? assistantSocket
                    ZeusMenuPicker("Terminal pane", choices: Self.paneChoices(panes: panes, saved: settings.tmuxTarget),
                        selection: Binding(get: { settings.tmuxTarget }, set: { Self.selectPane($0, panes: panes, socketPath: socket, settings: settings) }),
                        placeholder: ZeusSettingsCopy.choosePanePlaceholder)
                    Button(discovery.isLoading ? "Refreshing…" : "Refresh") { Task { await discovery.refresh(socketPath: assistantSocket, assistantName: settings.backend.name) } }
                        .accessibilityLabel("Refresh Terminal Panes")
                        .disabled(discovery.isLoading)
                }
                TmuxTargetField(settings: settings, socketPath: assistantSocket)
                if let guidance = discovery.guidance { Text(guidance).settingsCaption() }
                if let error = discovery.error { Text(error).settingsError() }
            }
            if settings.backend == .opencode || settings.deliveryMethod == .opencode {
                OpenCodeServerField(settings: settings)
                if let message = settings.openCodeURLValidationMessage { Text(message).settingsCaption() }
                HStack {
                    OpenCodePasswordField(password: $password, save: savePassword)
                    Button(passwordSaved ? "Saved" : "Save", action: savePassword).accessibilityLabel("Save OpenCode Password")
                    Button("Remove") { if settings.saveOpenCodePassword(nil) { password = ""; passwordSaved = false } }.accessibilityLabel("Remove OpenCode Password")
                }
                Text("Saved in your Mac's Keychain. Leave it empty if your server has no password.").settingsCaption()
                if let error = settings.passwordError { Text(error).settingsError() }
                if settings.deliveryMethod == .opencode { OpenCodeSessionPicker(settings: settings, messaging: messaging) }
            }
            SettingsDivider()
            Text("Setup").settingsTitle()
            if let bridge = SetupCommands.embeddedBridgeURL {
                ForEach(Array(SetupCommands.steps(for: settings.backend, bridgePath: bridge.path).enumerated()), id: \.element.id) { index, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).settingsHeading()
                        Text(step.detail).settingsCaption().textSelection(.enabled)
                        if index == 0 {
                            CopyableCommand(title: settings.backend == .opencode ? "The Zeus block for opencode.json:" : "Add Zeus (run once):",
                                            text: SetupCommands.configuration(for: settings.backend, bridgePath: bridge.path))
                        }
                        if let command = step.command { CopyableCommand(title: "Start it with:", text: command) }
                    }
                }
                DisclosureGroup("Read the full setup guide") {
                    Text(SetupCommands.guide(bridgePath: bridge.path)).settingsCaption().textSelection(.enabled)
                    Link("OpenCode configuration reference", destination: URL(string: "https://opencode.ai/docs/config/")!)
                }
            }
            if SetupCommands.embeddedBridgeURL == nil { Text("Part of Zeus is missing. Reinstall Zeus, then set up your agent.").settingsCaption() }
            Button(testMessage.isSending ? "Sending…" : "Send Test Message") {
                testMessage.draft = "Hello from Zeus — this is a test message."
                Task { await testMessage.send() }
            }
            .accessibilityLabel(testMessage.isSending ? "Sending Test Message" : "Send Test Message")
            .buttonStyle(ZeusButtonStyle(.primary, size: .small)).disabled(testMessage.isSending)
            if let result = testMessage.result { SendResultView(result: result) }

        }
        .settingsBody()
        .onAppear { password = settings.openCodeServerPassword ?? "" }
        .onChange(of: password) { passwordSaved = false }
        .task(id: discoveryRequest) {
            if settings.deliveryMethod == .tmux {
                settings.revalidateTmuxTarget(socketPath: assistantSocket)
                await discovery.refresh(socketPath: assistantSocket, assistantName: settings.backend.name)
            }
        }
    }

    static func paneChoices(panes: [TmuxPane], saved: String?) -> [ZeusChoice<String>] {
        var choices = panes.map { ZeusChoice(id: $0.id, title: $0.label) }
        if let saved, !panes.contains(where: { $0.id == saved }) { choices.append(ZeusChoice(id: saved, title: "Saved pane · \(saved)")) }
        return choices
    }
    static func selectPane(_ id: String?, panes: [TmuxPane], socketPath: String?, settings: AppSettings) {
        guard let id else { return } // A prompt opens the menu; it never forgets the saved pane.
        // A menu can stay open while Auto changes. Preserve the namespace of the displayed choice.
        let socket = panes.first { $0.id == id }?.socketPath ?? socketPath
        settings.setTmuxTarget(id, socketPath: socket)
    }

    private var assistantSocket: String? { settings.selectedAssistant(in: messaging.sessions)?.tmuxSocketPath }
    private var discoveryRequest: String { [settings.deliveryMethod.rawValue, settings.assistantSessionKey ?? "auto", assistantSocket ?? "offline", settings.selectedAssistant(in: messaging.sessions)?.sessionKey ?? "none"].joined(separator: "\n") }

    private func savePassword() { passwordSaved = settings.saveOpenCodePassword(password.isEmpty ? nil : password) }

    private var uniqueSessions: [ConnectedSession] { SessionLabels.unique(messaging.sessions) }

}

/// The same full-key choices and labels appear in Settings and the menu bar.
struct AssistantSessionPicker: View {
    @Bindable var settings: AppSettings
    let sessions: [ConnectedSession]

    var menuChrome = true
    static func autoTitle(settings: AppSettings, sessions: [ConnectedSession]) -> String {
        ZeusSettingsCopy.Auto.title(current: settings.automaticAssistant(in: sessions).map { settings.sessionLabels.label($0.sessionKey) })
    }
    static func choices(settings: AppSettings, sessions: [ConnectedSession]) -> [ZeusChoice<String>] {
        var choices: [ZeusChoice<String>] = []
        if let key = settings.assistantSessionKey, !sessions.contains(where: { $0.sessionKey == key }) {
            choices.append(ZeusChoice(id: key, title: settings.sessionLabels.label(key) + " · offline"))
        }
        choices += settings.assistantCandidates(sessions).map {
            ZeusChoice(id: $0.sessionKey, title: settings.sessionLabels.label($0.sessionKey), detail: SessionLabels.processCaption(for: $0))
        }
        return choices
    }
    var body: some View {
        let choices = Self.choices(settings: settings, sessions: sessions)
        let autoTitle = Self.autoTitle(settings: settings, sessions: sessions)
        let explanation = ZeusSettingsCopy.Auto.explanation(agent: settings.backend.name, prefersDirect: settings.backend == .claude)
        Group {
            if menuChrome {
                VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
                    ZeusMenuPicker("Assistant session", choices: choices, selection: $settings.assistantSessionKey, noneTitle: autoTitle)
                    Text(explanation).settingsCaption()
                }
            } else {
                Picker("Assistant session", selection: $settings.assistantSessionKey) {
                    Text(autoTitle).tag(String?.none).help(explanation)
                    ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
                }
            }
        }
    }
}

private struct CopyableCommand: View {
    let title: String
    let text: String

    var body: some View {
        // The Zeus command row (D2-3): the command in a field, Copy → "Copied". Multi-line configs show in full.
        ZeusCommandRow(title, command: text, lines: text.contains("\n") ? nil : 1) { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Uses the same field chrome and placeholder treatment as other Settings controls.
struct TmuxTargetField: View {
    @Bindable var settings: AppSettings
    let socketPath: String?
    var body: some View {
        ZeusTextField("Or type a tmux pane, such as %3", text: Binding(
            get: { settings.tmuxTarget ?? "" },
            set: { settings.setTmuxTarget($0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0, socketPath: socketPath) }))
            .disabled(socketPath == nil)
    }
}

/// The server field keeps its visible label after a URL has been entered.
struct OpenCodeServerField: View {
    @Bindable var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text("Server URL").settingsHeading()
            ZeusTextField("OpenCode server URL", text: $settings.openCodeURLText)
                .accessibilityLabel("Server URL")
        }
    }
}

/// Secure input uses the same secondary placeholder and field chrome as the server URL.
struct OpenCodePasswordField: View {
    @Binding var password: String
    var save: () -> Void
    var body: some View {
        ZeusTextField("OpenCode server password", text: $password, secure: true)
            .onSubmit(save)
    }
}
