import AppKit
import SwiftUI
import ZeusDesign
import ZeusProtocol

struct AssistantSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var managed: ManagedAssistantModel
    let messaging: AgentMessagingHub
    let testMessage: ComposeModel
    @Environment(\.zeusPalette) private var palette
    @Environment(\.zeusAnimationsActive) private var active
    @State private var choosingFolder = false
    @FocusState private var confirmationFocused: Bool
    @FocusState private var instructionsFocused: Bool
    private var selectedAgentName: String { ManagedAssistantModel.name(managed.config.agent) }

    static let setupChoices: [ZeusChoice<Bool>] = [
        .init(id: true, title: "Zeus runs it", detail: "Choose an agent and folder. Zeus starts and looks after your assistant."),
        .init(id: false, title: "Connect your own", detail: "Connect an agent you already run and manage yourself.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.l) {
            ZeusChoiceList(Self.setupChoices, selection: Binding(get: { managed.enabled }, set: { mode in
                if let mode { managed.chooseManaged(mode) }
            }))
            .disabled(managed.switching)
            if let error = settings.managedSettingsError { Text(error).zeusFont(.caption).foregroundStyle(palette.destructive) }
            if managed.confirmation == .switchToOwn {
                confirmation("Stop the Zeus-run agent?", action: "Stop", cancel: "Keep Running",
                    onCancel: managed.keepRunningAndConnectOwn)
            }
            if managed.switching { caption("Stopping \(managed.agentName)…") }
            if managed.enabled { managedContent }
            else {
                if let notice = managed.retainedSessionNotice { caption(notice).textSelection(.enabled) }
                AgentSettingsView(settings: settings, messaging: messaging, testMessage: testMessage)
            }
            SettingsDivider()
            QuietHoursSettingsView(settings: settings)
        }
        .onAppear { managed.refreshAvailability() }
        .onChange(of: messaging.runtime.map { ObjectIdentifier($0) }) { managed.refreshAvailability() }
        .onChange(of: active) { _, visible in if visible { managed.refreshAvailability() } }
        .task(id: active && managed.retainedSessionNotice != nil) {
            guard active && managed.retainedSessionNotice != nil else { return }
            while !Task.isCancelled {
                managed.refreshRetainedSession()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    @ViewBuilder private var managedContent: some View {
        AgentLinkStatusView(hub: messaging)
        if case .restarting = managed.status, active {
            TimelineView(.periodic(from: .now, by: 1)) { context in statusPanel(now: context.date) }
        } else { statusPanel(now: Date()) }
        if managed.agentUpdatePending || managed.agentUpdateRestartPending {
            HStack(spacing: ZeusTheme.Spacing.s) {
                caption(managed.agentUpdateRestartPending ? managed.agentUpdateWaitingText : "Update available")
                if !managed.agentUpdateRestartPending {
                    KeyboardButton("Restart assistant") { managed.requestAgentUpdateRestart() }
                        .accessibilityLabel("Restart assistant to use the update")
                        .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                        .disabled(!managed.agentUpdateCanRestart)
                }
            }
        }
        if case .restartForUpdate(let mode) = managed.confirmation {
            confirmation("Restart \(managed.agentName) with \(mode.title)? It can run any command and change any file you can, without asking. The conversation is kept.", action: "Restart assistant", cancel: "Later")
                .id("agentUpdateConfirmation")
        }
        if managed.confirmation == .newConversation {
            confirmation("Start a new conversation? \(selectedAgentName) starts fresh with these instructions.", action: "Start New")
                .id("newConversationConfirmation")
        }
        if managed.confirmation == .switchConversation {
            confirmation(managed.switchConfirmation, action: "Switch Now", cancel: "Later")
                .id("switchConversationConfirmation")
        }
        HStack {
            title("Agent")
            Spacer()
            // Only useful after installing an agent while Settings is open (D2-19).
            if managed.showsCheckAgain {
                KeyboardButton("Check Again") { managed.refreshAvailability() }
                    .accessibilityLabel("Check Again")
                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
            }
        }
        ZeusChoiceList(ManagedAssistantModel.agents.map { agent in
            let installed = !(managed.modes[agent] ?? []).isEmpty
            return ZeusChoice(id: agent, title: ManagedAssistantModel.name(agent),
                detail: managed.agentDetail(agent),
                isEnabled: installed)
        }, selection: Binding(get: { managed.config.agent }, set: { if let agent = $0 { managed.chooseAgent(agent) } }))
        title("Folder")
        HStack(spacing: ZeusTheme.Spacing.s) {
            ManagedFolderField(settings: settings)
            KeyboardButton("Choose…", action: chooseFolder).accessibilityLabel("Choose Folder").buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                .disabled(choosingFolder)
        }
        if managed.createFolder != nil {
            KeyboardButton("Create one for me") { managed.createDefaultFolder() }.accessibilityLabel("Create one for me")
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).disabled(choosingFolder || managed.switching)
        }
        caption(managed.config.agent == .claude ? "It works here, and reads this folder's CLAUDE.md or AGENTS.md." : "It works here, and reads this folder's AGENTS.md.")
        title("Permissions")
        ZeusChoiceList(managed.permissionModes.map { mode in
            ZeusChoice(id: mode.id, title: mode.title, detail: mode.detail,
                tag: mode.isUnrestricted ? "Unrestricted" : mode.isDefault ? "Default" : nil, isWarning: mode.isUnrestricted)
        }, selection: Binding(get: { managed.selectedPermissionID }, set: { if let id = $0 { managed.choosePermission(id) } }))
        if case .unrestricted(let mode) = managed.confirmation {
            confirmation("\(mode.title) lets \(selectedAgentName) run any command and change any file you can, without asking.", action: "Use Unrestricted")
        }
        caption("\(selectedAgentName)'s own modes. When it asks, Zeus shows a card that opens Terminal.")
        caption("Logins and folder-trust prompts always wait for you in Terminal.")
        title("Instructions")
        ZeusFieldChrome { TextEditor(text: Binding(get: { managed.config.launchPrompt }, set: { prompt in managed.update { $0.launchPrompt = prompt } }))
            .font(.system(size: 13)).foregroundStyle(palette.text).tint(palette.focusRing).scrollContentBackground(.hidden).frame(height: 148)
            .focused($instructionsFocused)
            .accessibilityLabel("Assistant instructions") }
        .onChange(of: instructionsFocused) { _, focused in if !focused { managed.finishInstructionsEditing() } }
        .onDisappear { managed.finishInstructionsEditing() }
        caption(managed.instructionsCaption)
        HStack(spacing: ZeusTheme.Spacing.s) {
            KeyboardButton("Start a New Conversation") { managed.confirmation = .newConversation }.accessibilityLabel("Start a New Conversation")
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).disabled(!managed.canStart)
            KeyboardButton("Reset to Default") { managed.update { $0.launchPrompt = ZeusManagedCopy.defaultLaunchPrompt } }.accessibilityLabel("Reset to Default")
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                .disabled(managed.config.launchPrompt == ZeusManagedCopy.defaultLaunchPrompt)
        }
        Toggle("Start when Zeus opens", isOn: Binding(get: { managed.config.startWhenZeusOpens }, set: { value in managed.update { $0.startWhenZeusOpens = value } }))
            .accessibilityLabel("Start when Zeus opens")
            .toggleStyle(ZeusCheckboxStyle()).disabled(managed.config.folder.isEmpty)
    }
    private func statusPanel(now: Date) -> some View {
        ZeusManagedStatusPanel(managed.presentation(now: now), attachCommand: managed.attachCommand, note: managed.note,
            disabledActions: managed.disabledActions, onAction: managed.perform, onCopy: { text in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            })
            .disabled(managed.switching)
    }
    private func confirmation(_ text: String, action: String, cancel: String = "Cancel", onCancel: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text(text).zeusFont(.caption).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZeusTheme.Spacing.s) {
                KeyboardButton(action) { managed.confirm() }.accessibilityLabel(action).buttonStyle(ZeusButtonStyle(.destructive, size: .small))
                KeyboardButton(cancel, focus: $confirmationFocused) { if let onCancel { onCancel() } else { managed.cancelConfirmation() } }.accessibilityLabel(cancel).buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    .keyboardShortcut(.cancelAction)
            }
        }.padding(ZeusTheme.Spacing.s).background(palette.field)
            .onAppear { confirmationFocused = true }
    }
    private func title(_ text: String) -> some View { Text(text).zeusFont(.title).foregroundStyle(palette.title) }
    private func caption(_ text: String) -> some View { Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true) }
    private func chooseFolder() {
        guard !choosingFolder else { return }
        choosingFolder = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"; panel.message = "Choose the folder your assistant works in."
        if !managed.config.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: managed.config.folder, isDirectory: true) }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            choosingFolder = false
            if response == .OK, let url = panel.url { managed.chooseFolder(url.path) }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

struct QuietHoursSettingsView: View {
    @Bindable var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Quiet hours", isOn: $settings.quietHoursEnabled).accessibilityLabel("Quiet hours")
            HStack {
                Picker("From", selection: $settings.quietStartHour) { hours }
                Picker("Until", selection: $settings.quietEndHour) { hours }
            }.disabled(!settings.quietHoursEnabled)
            Text("Local time. Equal start and end means all day. Questions and agent activity take precedence.").settingsCaption()
        }
    }
    private var hours: some View { ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) } }
}

/// Reads the persisted configuration directly and rebuilds selectable text when its path changes.
struct ManagedFolderField: View {
    @Bindable var settings: AppSettings
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        let folder = settings.managedSession?.folder ?? ""
        ZeusFieldChrome {
            Text(folder.isEmpty ? "Choose a folder" : (folder as NSString).abbreviatingWithTildeInPath)
                .zeusFont(.body).foregroundStyle(folder.isEmpty ? palette.secondaryText : palette.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(folder)
        }
        .help(folder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder")
        .accessibilityValue(folder.isEmpty ? "Choose a folder" : folder)
    }
}
