import Foundation
import Observation
import ZeusProtocol
import ZeusDesign

/// Presentation reads the native conversation identity when adopting a session; pending
/// editor preferences cannot stand in for what the controller actually launched.
@MainActor enum ManagedPresentationConfiguration {
    static func current(desired: ManagedSessionConfig?, launched: ManagedSessionConfig?, controller: (any ManagedSessionControlling)?) -> ManagedSessionConfig? {
        guard let desired, desired.enabled else { return desired }
        switch controller?.managedStatus {
        case .starting?, .running?, .blocked?, .restarting?: break
        default: return desired
        }
        if let runtime = controller as? ZeusRuntime, let conversation = runtime.managedController.record?.conversation {
            var current = launched ?? desired
            current.enabled = true
            current.agent = conversation.agent; current.folder = conversation.folder; current.launchPrompt = conversation.launchPrompt
            return current
        }
        // Persisted UI launch data is authoritative for adapters that expose only the seam.
        // Without either identity source, use generic copy instead of claiming pending edits are running.
        return launched
    }
}

/// App-owned confirmations and configuration editing; only explicit lifecycle actions reach the controller.
@MainActor @Observable
final class ManagedAssistantModel {
    enum Confirmation: Equatable {
        case switchToOwn
        case unrestricted(ManagedPermissionMode)
        case newConversation
    }
    static let agents: [AgentKind] = [.claude, .codex, .opencode]
    let settings: AppSettings
    var createFolder: (() throws -> URL)?
    var confirmation: Confirmation?
    private(set) var switching = false
    private(set) var actionError: String?
    private(set) var modes: [AgentKind: [ManagedPermissionMode]] = [:]
    private(set) var requirements: [AgentKind: String] = [:]
    private var launchedConfig: ManagedSessionConfig? {
        get { settings.managedLaunchedConfig }
        set { settings.managedLaunchedConfig = newValue }
    }
    @ObservationIgnored private let controllerProvider: () -> (any ManagedSessionControlling)?

    init(settings: AppSettings, controller: @escaping () -> (any ManagedSessionControlling)?) {
        self.settings = settings
        controllerProvider = controller
        reconcileStatus()
        observeStatus()
    }

    var controller: (any ManagedSessionControlling)? { controllerProvider() }
    var config: ManagedSessionConfig { settings.managedSession ?? AppSettings.newManagedSession(enabled: false) }
    var enabled: Bool { config.enabled }
    var status: ManagedSessionStatus { controller?.managedStatus ?? .off }
    var requiresFreshConversation: Bool {
        enabled && (controller as? any ManagedPresentationProviding)?.managedNeedsNewConversation == true
    }
    var isNotStarted: Bool {
        enabled && (status == .off || status == .stopped)
            && (controller as? any ManagedPresentationProviding)?.managedHasLaunched == false
    }
    var currentConfiguration: ManagedSessionConfig? {
        ManagedPresentationConfiguration.current(desired: settings.managedSession, launched: launchedConfig, controller: controller)
    }
    var agentName: String { hasActiveSession ? currentConfiguration.map { Self.name($0.agent) } ?? "Your assistant" : Self.name(config.agent) }
    private var currentFolderLabel: String { (currentConfiguration?.folder as NSString?)?.abbreviatingWithTildeInPath ?? "its folder" }
    private var comparisonConfiguration: ManagedSessionConfig? { hasActiveSession ? currentConfiguration : launchedConfig }
    var folderLabel: String { (config.folder as NSString).abbreviatingWithTildeInPath }
    var attachCommand: String? {
        guard enabled, status != .off, let command = controller?.managedAttachCommand else { return nil }
        guard let session = controller?.managedTmuxSessionName,
              let socket = (controller as? any ManagedTerminalPresenting)?.managedTerminalSocketPath else { return command }
        return ManagedTerminalPresentation.attach(session: session, socket: socket)
    }
    var permissionModes: [ManagedPermissionMode] { modes[config.agent] ?? [] }
    var selectedPermissionID: String? { config.permissionModeID ?? permissionModes.first(where: \.isDefault)?.id }
    var requirementsProblem: String? { requirements[config.agent] }
    var canStart: Bool { enabled && controller != nil && !config.folder.isEmpty && requirementsProblem == nil && !permissionModes.isEmpty && !switching }
    var disabledActions: Set<ZeusManagedPresentation.Action> {
        var actions: Set<ZeusManagedPresentation.Action> = canStart ? [] : [.start, .tryAgain, .restart, .restartNow, .newConversation]
        if attachCommand == nil { actions.insert(.openInTerminal) }
        return actions
    }
    var hasActiveSession: Bool {
        switch status { case .starting, .running, .blocked, .restarting: true; default: false }
    }
    var needsRestart: Bool {
        guard hasActiveSession, let current = comparisonConfiguration else { return false }
        return config.agent != current.agent || config.folder != current.folder || config.permissionModeID != current.permissionModeID
    }
    var needsNewConversation: Bool {
        guard let current = comparisonConfiguration else { return false }
        return config.agent != current.agent || config.folder != current.folder
    }
    private var recoveryAgentName: String {
        let previous = (controller as? ZeusRuntime)?.managedController.record?.conversation?.agent ?? launchedConfig?.agent ?? config.agent
        return Self.name(previous)
    }
    var note: String? {
        if let actionError { return actionError }
        if settings.managedSettingsError != nil { return settings.managedSettingsError }
        if controller == nil { return Self.noControllerNote }
        if needsRestart && !requiresFreshConversation { return ZeusManagedCopy.restartToApply }
        return requirementsProblem
    }
    /// Self-contained: the link-status block above it isn't always shown (D3-8).
    static let noControllerNote = "Zeus isn't connected to your assistant yet, so it can't start one. If this doesn't clear, quit and reopen Zeus."
    /// An agent row's second line. Without a controller nothing has been checked, and the note says so once (D3-8).
    func agentDetail(_ agent: AgentKind) -> String? {
        guard controller != nil, (modes[agent] ?? []).isEmpty else { return nil }
        return requirements[agent] ?? "Zeus couldn't check this agent. Press Check Again."
    }
    /// "Check Again" only does something with a controller, and only helps while an agent is missing (D2-19, D3-8).
    var showsCheckAgain: Bool { controller != nil && Self.agents.contains { (modes[$0] ?? []).isEmpty } }
    var isMenuAlert: Bool {
        guard enabled else { return false }
        if requiresFreshConversation { return true }
        return switch status { case .blocked, .failed: true; default: false }
    }
    /// Managed state owns the status line; unread messages have a separate count row.
    var prioritizesMenuStatus: Bool { enabled }
    var menuActions: [ZeusManagedPresentation.Action] {
        guard enabled else { return [] }
        var actions: [ZeusManagedPresentation.Action] = []
        if requiresFreshConversation {
            return [.newConversation] + (controller?.managedTmuxSessionName == nil ? [] : [.openInTerminal])
        }
        if controller?.managedTmuxSessionName != nil { actions.append(.openInTerminal) }
        switch status {
        case .off, .stopped: actions.append(.start)
        case .failed: actions.append(.start)
        case .starting, .running, .blocked, .restarting: actions += [.restart, .stop]
        }
        return actions
    }
    func presentation(now: Date = Date()) -> ZeusManagedPresentation {
        var result = ZeusManagedPresentation.make(Self.designState(status), agent: agentName,
            folder: hasActiveSession ? currentFolderLabel : folderLabel, session: controller?.managedTmuxSessionName, now: now)
        if case .failed = status { result.actions = result.actions.map { $0 == .tryAgain ? .start : $0 } }
        if (status == .off || status == .stopped) && config.folder.isEmpty { result.detail = "Choose a folder to start." }
        if isNotStarted {
            result.title = "Ready to Start"
            result.detail = config.folder.isEmpty ? "Choose a folder to start." : "\(agentName) isn't running. Press Start when you want it."
            result.menuStatus = "\(agentName) hasn't started"
            result.actions = [.start]
        } else if status == .stopped {
            // The seam doesn't distinguish an explicit Stop from a clean CLI exit.
            result.detail = "\(agentName) is stopped. Press Start to run it again."
        }
        if requiresFreshConversation {
            result.tone = .attention
            result.title = ZeusRuntimeCopy.Managed.cantResumeTitle
            result.detail = ZeusRuntimeCopy.Managed.cantResume(agent: recoveryAgentName)
            result.menuStatus = ZeusRuntimeCopy.Managed.cantResumeTitle
            result.actions = [.newConversation] + (attachCommand == nil ? [] : [.openInTerminal])
        } else if needsRestart {
            switch status {
            case .running, .starting:
                result.actions.removeAll { $0 == .restart }; result.actions.insert(.restart, at: 0)
            default: break
            }
        }
        return result
    }
    func menuStatus(usual: String, unread: Int) -> String {
        guard enabled else { return usual }
        let current = presentation()
        return current.menuStatus ?? current.detail
    }
    func refreshAvailability() {
        guard let controller else { return }
        var modes: [AgentKind: [ManagedPermissionMode]] = [:]
        var problems: [AgentKind: String] = [:]
        for agent in Self.agents {
            modes[agent] = controller.permissionModes(for: agent)
            problems[agent] = controller.managedRequirementsProblem(for: agent)
        }
        self.modes = modes; requirements = problems
        if settings.managedConfigurationWasFresh, !settings.managedAgentInitialized, settings.managedSettingsError == nil, let installed = Self.agents.first(where: { !(modes[$0] ?? []).isEmpty }) {
            update { $0.agent = installed; $0.permissionModeID = nil }
            settings.managedAgentInitialized = true
        }
    }
    func chooseManaged(_ managed: Bool) {
        guard managed != enabled, !switching else { return }
        confirmation = nil; actionError = nil
        if !managed && (hasActiveSession || controller?.managedTmuxSessionName != nil) { confirmation = .switchToOwn; return }
        // The controller activates on an enabled transition. Keep that transition explicitly manual.
        update { $0.enabled = managed; if managed { $0.startWhenZeusOpens = false } }
    }
    func chooseAgent(_ agent: AgentKind) {
        guard Self.agents.contains(agent), !(modes[agent] ?? []).isEmpty, agent != config.agent else { return }
        confirmation = nil
        settings.managedAgentInitialized = true
        update { $0.agent = agent; $0.permissionModeID = nil }
    }
    func choosePermission(_ id: String) {
        guard let mode = permissionModes.first(where: { $0.id == id }), id != selectedPermissionID else { return }
        confirmation = mode.isUnrestricted ? .unrestricted(mode) : nil
        if !mode.isUnrestricted { update { $0.permissionModeID = mode.isDefault ? nil : mode.id } }
    }
    func createDefaultFolder() {
        guard let createFolder else { return }
        actionError = nil
        do { chooseFolder(try createFolder().path) }
        catch { actionError = "Couldn't create your assistant folder. \(error.localizedDescription)" }
    }
    func chooseFolder(_ path: String) {
        guard path.hasPrefix("/"), !path.contains("\0") else { return }
        confirmation = nil
        let firstFolder = config.folder.isEmpty
        update { $0.folder = path; if firstFolder { $0.startWhenZeusOpens = true } }
    }
    func update(_ edit: (inout ManagedSessionConfig) -> Void) {
        var next = config; edit(&next)
        if next != settings.managedSession { settings.managedSession = next }
    }
    func cancelConfirmation() { confirmation = nil }
    func confirm() {
        guard let confirmation else { return }
        self.confirmation = nil; actionError = nil
        switch confirmation {
        case .switchToOwn:
            guard let controller else { return }
            let previousStatus = status
            switching = true
            controller.stopManagedSession()
            // An async Stop may still expose the previous failure until its operation starts.
            if status != previousStatus || (status == .stopped && controller.managedTmuxSessionName == nil) { reconcileStatus() }
        case .unrestricted(let mode):
            guard permissionModes.contains(mode) else { return }
            update { $0.permissionModeID = mode.id }
        case .newConversation:
            refreshAvailability()
            guard canStart else { return }
            launchedConfig = config
            controller?.startNewManagedConversation()
        }
    }
    func perform(_ action: ZeusManagedPresentation.Action) {
        guard !switching, let controller else { return }
        actionError = nil
        switch action {
        case .start, .tryAgain:
            refreshAvailability()
            guard canStart else { return }
            if needsNewConversation || requiresFreshConversation { confirmation = .newConversation; return }
            launchedConfig = config; controller.startManagedSession()
        case .restart, .restartNow:
            refreshAvailability()
            guard canStart else { return }
            if needsNewConversation || requiresFreshConversation { confirmation = .newConversation; return }
            launchedConfig = config; controller.restartManagedSession()
        case .stop: controller.stopManagedSession()
        case .openInTerminal: controller.openManagedSessionInTerminal()
        // The same confirmation as Settings' Start a New Conversation button (A4D-6).
        case .newConversation:
            refreshAvailability()
            if canStart { confirmation = .newConversation }
        }
    }
    private func reconcileStatus() {
        if switching {
            switch status {
            case .stopped:
                // The controller announces stopped before async teardown. Wait for the owned pane to be released.
                if controller?.managedTmuxSessionName == nil {
                    switching = false; update { $0.enabled = false }
                }
            case .failed(let reason):
                switching = false; actionError = "Couldn't stop the assistant. \(reason)"
            default: break
            }
        }
        if launchedConfig == nil, hasActiveSession, let currentConfiguration { launchedConfig = currentConfiguration }
    }
    private func observeStatus() {
        withObservationTracking { _ = status; _ = controller?.managedTmuxSessionName; _ = currentConfiguration } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileStatus()
                self.observeStatus()
            }
        }
    }
    static func name(_ agent: AgentKind) -> String {
        switch agent { case .claude: "Claude Code"; case .codex: "Codex"; case .opencode: "OpenCode"; case .other: "Agent" }
    }
    static func designState(_ status: ManagedSessionStatus) -> ZeusManagedState {
        switch status {
        case .off: return .off
        case .starting: return .starting
        case .running(let activity):
            let mapped: ZeusManagedState.Activity = switch activity { case .idle: .idle; case .working: .working; case .unknown: .unknown }
            return .running(mapped)
        case .blocked(let reason): return .blocked(reason: reason)
        case .stopped: return .stopped
        case .restarting(let at): return .restarting(at: at)
        case .failed(let reason): return .failed(reason: reason)
        }
    }
}
