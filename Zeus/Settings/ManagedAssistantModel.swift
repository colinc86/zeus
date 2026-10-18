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
        case restartNow
        case switchConversation
        case restartForUpdate(ManagedPermissionMode)
        case restartForSetup(ManagedPermissionMode)
    }
    static let agents: [AgentKind] = [.claude, .codex, .opencode]
    let settings: AppSettings
    var createFolder: (() throws -> URL)?
    @ObservationIgnored var hasPendingQuestion: () -> Bool = { false }
    var templateReplacement: ManagedTemplateReplacement?
    @ObservationIgnored private var replacementProvider: ObjectIdentifier?
    @ObservationIgnored private var setupConfirmationConfiguration: ManagedSessionConfig?
    @ObservationIgnored private var setupConfirmationProvider: ObjectIdentifier?
    @ObservationIgnored private var setupConfirmationConversation: String?
    var confirmation: Confirmation?
    private(set) var switching = false
    private(set) var actionError: String?
    private(set) var instructionsAreDebouncing = false
    private(set) var retainedSession: RetainedManagedSession?
    @ObservationIgnored private let instructionDebouncer: ManagedInstructionsDebouncer
    @ObservationIgnored private var observedConfiguration: ManagedSessionConfig?
    @ObservationIgnored private var recoveryConfirmationToken: String?
    @ObservationIgnored private var recoveryConfirmationProvider: ObjectIdentifier?
    @ObservationIgnored private var updateConfirmationConversation: String?
    @ObservationIgnored private var confirmedSwitchTarget: ManagedSessionConfig?
    private(set) var modes: [AgentKind: [ManagedPermissionMode]] = [:]
    private(set) var requirements: [AgentKind: String] = [:]
    private var launchedConfig: ManagedSessionConfig? {
        get { settings.managedLaunchedConfig }
        set { settings.managedLaunchedConfig = newValue }
    }
    @ObservationIgnored private let controllerProvider: () -> (any ManagedSessionControlling)?

    init(settings: AppSettings, controller: @escaping () -> (any ManagedSessionControlling)?, instructionDebouncer: ManagedInstructionsDebouncer = .init()) {
        self.settings = settings
        controllerProvider = controller
        self.instructionDebouncer = instructionDebouncer
        observedConfiguration = settings.managedSession
        reconcileStatus()
        observeStatus()
    }

    var controller: (any ManagedSessionControlling)? { controllerProvider() }
    private var settingsApplier: (any ManagedSettingsApplying)? { controller as? any ManagedSettingsApplying }
    var agentUpdater: (any ManagedAgentUpdating)? { controller as? any ManagedAgentUpdating }
    var agentUpdatePending: Bool { enabled && agentUpdater?.managedAgentUpdatePending == true }
    var agentUpdateRestartPending: Bool { settingsApplier?.managedSettingsApplication?.kind == .agentUpdate }
    var agentUpdateRestartID: UUID? { agentUpdater?.managedAgentUpdateLastRestartID }
    var agentUpdateRestartError: String? { settingsApplier?.managedSettingsApplicationError }
    var agentUpdateCanRestart: Bool {
        agentUpdatePending && hasActiveSession && settingsApplier?.managedCanResumeSettings == true
            && settingsApplier?.managedSettingsApplication == nil && !switching && !hasPendingQuestion()
    }
    private var restartRecovery: (any ManagedRestartRecovering)? { controller as? any ManagedRestartRecovering }
    var canRestartNow: Bool { enabled && !switching && restartRecovery?.managedRestartNowToken != nil }
    var ordinaryRestartPending: Bool { settingsApplier?.managedSettingsApplication?.kind == .restart }
    var canCancelRestart: Bool { ordinaryRestartPending && settingsApplier?.managedSettingsApplication?.phase == .waiting }
    func cancelRestart() { if canCancelRestart { settingsApplier?.cancelManagedSettingsApplication() } }
    var restartNowConfirmation: String {
        if case .blocked = status {
            return "Restart \(agentName) now? It's in the middle of something: restarting interrupts it and loses any unsent text in Terminal. The conversation is kept."
        }
        return "Restart \(agentName) now? Any unsent text in Terminal is lost. The conversation is kept."
    }
    var agentUpdateWaitingText: String { "Restarting when \(agentName) is idle…" }
    /// This action resumes the launched conversation, never a deferred agent/folder selection.
    func requestAgentUpdateRestart() {
        guard agentUpdateCanRestart, let applied = currentConfiguration else { return }
        let modes = controller?.permissionModes(for: applied.agent) ?? []
        let mode = modes.first { $0.id == applied.permissionModeID } ?? modes.first { $0.isDefault && applied.permissionModeID == nil }
        if let mode, mode.isUnrestricted { updateConfirmationConversation = agentUpdater?.managedAgentUpdateConversationID; confirmation = .restartForUpdate(mode); return }
        agentUpdater?.restartManagedAgentForUpdate()
    }
    var setupProvider: (any LearningDeliveryPresenting)? { controller as? any LearningDeliveryPresenting }
    var setupStale: ManagedSetupStaleness { setupProvider?.managedSetupStale ?? .init() }
    var setupNeedsRestart: Bool { enabled && (setupStale.tools || setupStale.template) }
    var setupCanRestart: Bool {
        setupNeedsRestart && hasActiveSession && settingsApplier?.managedCanResumeSettings == true
            && settingsApplier?.managedSettingsApplication == nil && !switching && !hasPendingQuestion()
    }
    var setupNote: String? {
        if agentUpdateRestartPending && setupNeedsRestart { return agentUpdateWaitingText }
        if setupStale.template && setupStale.templateEdited { return "Your assistant's instructions are older than Zeus's template. Open the folder to compare, or use the new template." }
        guard setupNeedsRestart else { return nil }
        return "Zeus has new \(Self.setupContent(setupStale)) for \(agentName). Restart to use them; the conversation is kept."
    }
    static func setupContent(_ stale: ManagedSetupStaleness) -> String {
        stale.tools && stale.template ? "tools and instructions" : stale.tools ? "tools" : "instructions"
    }
    func requestSetupRestart() {
        guard setupCanRestart, let provider = setupProvider, let applied = currentConfiguration else { return }
        let modes = controller?.permissionModes(for: applied.agent) ?? []
        let mode = modes.first { $0.id == applied.permissionModeID } ?? modes.first { $0.isDefault && applied.permissionModeID == nil }
        if let mode, mode.isUnrestricted {
            setupConfirmationConfiguration = applied; setupConfirmationProvider = ObjectIdentifier(provider)
            setupConfirmationConversation = agentUpdater?.managedAgentUpdateConversationID
            confirmation = .restartForSetup(mode); return
        }
        provider.restartManagedAssistantForSetup()
    }
    func requestTemplateReplacement() {
        guard setupCanRestart, let provider = setupProvider, provider.managedSetupStale.template && provider.managedSetupStale.templateEdited else { return }
        actionError = nil
        templateReplacement = provider.managedTemplateReplacement
        replacementProvider = ObjectIdentifier(provider)
        if templateReplacement == nil { actionError = "Couldn't read the instructions. Try again." }
    }
    func confirmTemplateReplacement() {
        guard let snapshot = templateReplacement else { return }
        templateReplacement = nil
        guard setupCanRestart,
              let provider = setupProvider, replacementProvider == ObjectIdentifier(provider),
              provider.managedTemplateReplacement == snapshot else {
            actionError = "The instructions changed. Review them before replacing them."; return
        }
        do {
            try provider.replaceEditedManagedTemplates(snapshot)
            requestSetupRestart()
        } catch { actionError = "Couldn't replace the instructions. \(error.localizedDescription)" }
    }
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
        ManagedPresentationConfiguration.current(desired: settings.managedSession, launched: settingsApplier?.managedAppliedConfiguration ?? launchedConfig, controller: controller)
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
        if setupNeedsRestart {
            if setupCanRestart { actions.remove(.restart) } else { actions.insert(.restart) }
        }
        if agentUpdatePending || agentUpdateRestartPending {
            if agentUpdateCanRestart { actions.remove(.restart) }
            else { actions.insert(.restart) }
        }
        if !canRestartNow { actions.insert(.restartNow) }
        if ordinaryRestartPending { actions.insert(.restart) }
        if attachCommand == nil { actions.insert(.openInTerminal) }
        return actions
    }
    var hasActiveSession: Bool {
        switch status { case .starting, .running, .blocked, .restarting: true; default: false }
    }
    /// A stopped Zeus-run assistant is distinct from a connected, user-run session.
    func assistantIsOff(connectedSessionCount: Int) -> Bool {
        guard controller != nil, connectedSessionCount == 0, retainedSession == nil,
              status == .off || status == .stopped else { return false }
        return enabled || launchedConfig != nil
    }
    var retainedSessionNotice: String? {
        guard !enabled, let retainedSession else { return nil }
        return "Your Zeus-run agent is still running in tmux (\(retainedSession.attachCommand))"
    }
    /// Settings refreshes this inexpensive process-lifetime check while visible.
    /// A bridge disconnect is not evidence that the agent exited.
    func refreshRetainedSession() {
        let next: RetainedManagedSession?
        if enabled { next = nil }
        else if let provider = controller as? any RetainedManagedSessionPresenting {
            next = provider.retainedManagedSession
        } else if hasActiveSession, let command = controller?.managedAttachCommand {
            next = .init(attachCommand: command)
        } else { next = nil }
        if next != retainedSession { retainedSession = next }
    }
    var needsRestart: Bool {
        guard hasActiveSession, let current = comparisonConfiguration else { return false }
        return config.agent != current.agent || !Self.sameFolder(config.folder, current.folder) || config.permissionModeID != current.permissionModeID
            || (supportsInstructionResume && config.launchPrompt != current.launchPrompt)
    }
    private var supportsInstructionResume: Bool { settingsApplier?.supportsInstructionChangesOnResume(for: config.agent) == true }
    var instructionsCaption: String {
        let selected = Self.name(config.agent)
        if hasActiveSession, !needsNewConversation, supportsInstructionResume, settingsApplier?.managedCanResumeSettings == true {
            return "Changes apply when \(selected) is ready. It restarts and keeps the same conversation."
        }
        if !supportsInstructionResume { return "\(selected) uses new instructions in the next new conversation." }
        return "Used when your assistant starts a new conversation."
    }
    var needsNewConversation: Bool {
        guard let current = comparisonConfiguration else { return false }
        return config.agent != current.agent || !Self.sameFolder(config.folder, current.folder)
    }
    var switchConfirmation: String {
        let next = Self.name(config.agent)
        if config.agent != currentConfiguration?.agent {
            return "Switch to \(next) now? \(agentName)'s conversation stays in \(currentFolderLabel); \(next) starts a new one."
        }
        return "Switch folders now? \(agentName)'s conversation stays in \(currentFolderLabel); \(next) starts a new one in \(folderLabel)."
    }
    private var recoveryAgentName: String {
        let previous = (controller as? ZeusRuntime)?.managedController.record?.conversation?.agent ?? launchedConfig?.agent ?? config.agent
        return Self.name(previous)
    }
    var note: String? {
        if let actionError { return actionError }
        if settings.managedSettingsError != nil { return settings.managedSettingsError }
        if controller == nil { return Self.noControllerNote }
        if let error = settingsApplier?.managedSettingsApplicationError { return error }
        if let pending = settingsApplier?.managedSettingsApplication {
            switch status {
            case .failed, .stopped, .off: return "Your changes are saved. Start the assistant to apply them."
            default: break
            }
            if pending.kind == .agentUpdate || pending.kind == .restart { return agentUpdateWaitingText }
            if pending.kind == .newConversation { return "Switching to \(Self.name(pending.configuration.agent)) in \((pending.configuration.folder as NSString).abbreviatingWithTildeInPath) when \(agentName) is ready." }
            if pending.phase == .applying && settingsApplier?.managedCanResumeSettings == true {
                return "Applying your changes. \(agentName) restarts and keeps the same conversation."
            }
            return "\(agentName) picks up your changes when it finishes what it's doing."
        }
        if let setupNote { return setupNote }
        if agentUpdatePending { return "\(agentName) has an update. Restart to use it; the conversation is kept." }
        if needsNewConversation { return "Switches to \(Self.name(config.agent)) in \(folderLabel) the next time it starts." }
        if instructionsAreDebouncing { return "Your instruction changes are saved." }
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
        case .starting, .running, .blocked: actions += [.restart, .stop]
        case .restarting: actions.append(.stop)
        }
        if canRestartNow {
            actions.removeAll { $0 == .start || $0 == .tryAgain }
            actions.append(.restartNow)
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
            result.menuStatus = "Your assistant is off"
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
        } else if setupNeedsRestart || agentUpdatePending || (needsRestart && settingsApplier?.managedSettingsApplication == nil && !instructionsAreDebouncing) {
            switch status {
            case .running, .starting:
                result.actions.removeAll { $0 == .restart }; result.actions.insert(.restart, at: 0)
            default: break
            }
        }
        if !canRestartNow { result.actions.removeAll { $0 == .restartNow } }
        else {
            if result.actions.contains(.start) || result.actions.contains(.tryAgain) {
                result.actions.removeAll { $0 == .start || $0 == .tryAgain || $0 == .restartNow }
                result.actions.insert(.restartNow, at: 0)
                result.detail = "\(recoveryAgentName) exited."
            } else if !result.actions.contains(.restartNow) { result.actions.append(.restartNow) }
        }
        return result
    }
    func menuStatus(usual: String, unread: Int) -> String {
        guard enabled else { return usual }
        if ordinaryRestartPending { return agentUpdateWaitingText }
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
        offerConversationSwitch()
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
        offerConversationSwitch()
    }
    func update(_ edit: (inout ManagedSessionConfig) -> Void) {
        let previous = config
        var next = previous; edit(&next)
        if next != settings.managedSession {
            settings.managedSession = next; observedConfiguration = next
            configurationEdited(previous: previous)
        }
    }
    /// Blur commits immediately; normal typing waits for the coalescing timer.
    func finishInstructionsEditing() { instructionDebouncer.flush() }
    private func configurationEdited(previous: ManagedSessionConfig) {
        guard previous.agent != config.agent || previous.folder != config.folder || previous.permissionModeID != config.permissionModeID
                || previous.launchPrompt != config.launchPrompt || previous.enabled != config.enabled else { return }
        if let target = confirmedSwitchTarget, target.agent != config.agent || !Self.sameFolder(target.folder, config.folder) || !enabled { confirmedSwitchTarget = nil }
        if previous.agent == config.agent && previous.folder == config.folder && previous.permissionModeID == config.permissionModeID
            && previous.enabled == config.enabled && !supportsInstructionResume && confirmedSwitchTarget == nil { return }
        instructionDebouncer.cancel(); instructionsAreDebouncing = false
        settingsApplier?.cancelManagedSettingsApplication()
        if let target = confirmedSwitchTarget, enabled, settingsApplier != nil {
            if previous.launchPrompt != config.launchPrompt {
                instructionsAreDebouncing = true
                instructionDebouncer.schedule { [weak self] in
                    guard let self else { return }
                    self.instructionsAreDebouncing = false; self.submitConfirmedSwitch(to: target)
                }
            } else { submitConfirmedSwitch(to: target) }
            return
        }
        guard hasActiveSession, enabled, !needsNewConversation, settingsApplier != nil else { return }
        if previous.launchPrompt != config.launchPrompt, config.launchPrompt != currentConfiguration?.launchPrompt, supportsInstructionResume {
            instructionsAreDebouncing = true
            instructionDebouncer.schedule { [weak self] in
                guard let self else { return }
                self.instructionsAreDebouncing = false; self.submitResumeSettingsIfNeeded()
            }
        } else { submitResumeSettingsIfNeeded() }
    }
    private func submitResumeSettingsIfNeeded() {
        guard hasActiveSession, enabled, !switching, !needsNewConversation, let current = currentConfiguration, let settingsApplier,
              current.permissionModeID != config.permissionModeID || (supportsInstructionResume && current.launchPrompt != config.launchPrompt) else { return }
        settingsApplier.applyManagedSettings(config)
    }
    private func submitConfirmedSwitch(to target: ManagedSessionConfig) {
        guard enabled, config.agent == target.agent, Self.sameFolder(config.folder, target.folder) else { return }
        if needsNewConversation { settingsApplier?.switchManagedSettings(config) }
        else { confirmedSwitchTarget = nil; submitResumeSettingsIfNeeded() }
    }
    func cancelConfirmation() {
        if confirmation == .switchConversation { confirmedSwitchTarget = nil }
        confirmation = nil
    }
    /// Keep Running is a mode switch, not a cancellation of the user's choice.
    func keepRunningAndConnectOwn() {
        guard confirmation == .switchToOwn, !switching else { return }
        confirmation = nil; actionError = nil
        update { $0.enabled = false }
        refreshRetainedSession()
    }
    private func offerConversationSwitch() {
        if hasActiveSession && needsNewConversation { confirmation = .switchConversation }
        else if confirmation == .switchConversation { confirmation = nil }
    }
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
        case .restartForSetup:
            guard setupCanRestart, let provider = setupProvider,
                  setupConfirmationProvider == ObjectIdentifier(provider), setupConfirmationConfiguration == currentConfiguration,
                  setupConfirmationConversation == agentUpdater?.managedAgentUpdateConversationID else { return }
            setupConfirmationProvider = nil; setupConfirmationConfiguration = nil
            provider.restartManagedAssistantForSetup()
        case .restartForUpdate:
            // Revalidate after the confirmation; a different conversation or resolved update is not authorized.
            guard agentUpdateCanRestart, updateConfirmationConversation == agentUpdater?.managedAgentUpdateConversationID else { return }
            updateConfirmationConversation = nil
            agentUpdater?.restartManagedAgentForUpdate()
        case .unrestricted(let mode):
            guard permissionModes.contains(mode) else { return }
            update { $0.permissionModeID = mode.id }
        case .switchConversation:
            refreshAvailability()
            guard canStart else { return }
            instructionDebouncer.cancel(); instructionsAreDebouncing = false
            if let settingsApplier { confirmedSwitchTarget = config; settingsApplier.switchManagedSettings(config) }
            else { launchedConfig = config; controller?.startNewManagedConversation() }
        case .restartNow:
            guard let recovery = restartRecovery, canRestartNow,
                  recoveryConfirmationProvider == ObjectIdentifier(recovery),
                  let token = recoveryConfirmationToken, recovery.managedRestartNowToken == token else { return }
            recoveryConfirmationToken = nil; recoveryConfirmationProvider = nil
            recovery.restartManagedSessionNow(token: token)
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
            if needsNewConversation { confirmation = .switchConversation; return }
            if requiresFreshConversation { confirmation = .newConversation; return }
            launchedConfig = config; controller.startManagedSession()
        case .restartNow:
            guard canRestartNow, let recovery = restartRecovery else { return }
            recoveryConfirmationToken = recovery.managedRestartNowToken
            recoveryConfirmationProvider = ObjectIdentifier(recovery)
            confirmation = .restartNow
        case .restart:
            if setupNeedsRestart { requestSetupRestart(); return }
            if agentUpdatePending || agentUpdateRestartPending { requestAgentUpdateRestart(); return }
            refreshAvailability()
            guard canStart else { return }
            if needsNewConversation { confirmation = .switchConversation; return }
            if requiresFreshConversation { confirmation = .newConversation; return }
            if needsRestart, settingsApplier != nil { finishInstructionsEditing(); submitResumeSettingsIfNeeded(); return }
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
        if let applied = settingsApplier?.managedAppliedConfiguration, launchedConfig != applied { launchedConfig = applied }
        if let target = confirmedSwitchTarget, let applied = settingsApplier?.managedAppliedConfiguration,
           applied.agent == target.agent && Self.sameFolder(applied.folder, target.folder) { confirmedSwitchTarget = nil }
        if observedConfiguration != settings.managedSession {
            let previous = observedConfiguration ?? config; observedConfiguration = settings.managedSession
            configurationEdited(previous: previous)
        }
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
        refreshRetainedSession()
        if !instructionsAreDebouncing && settingsApplier?.managedSettingsApplication == nil && settingsApplier?.managedSettingsApplicationError == nil {
            submitResumeSettingsIfNeeded()
        }
    }
    private func observeStatus() {
        withObservationTracking {
            _ = status; _ = controller?.managedTmuxSessionName; _ = currentConfiguration; _ = settings.managedSession
            _ = (controller as? any RetainedManagedSessionPresenting)?.retainedManagedSession
            _ = settingsApplier?.managedSettingsApplication; _ = settingsApplier?.managedSettingsApplicationError; _ = settingsApplier?.managedCanResumeSettings
            _ = supportsInstructionResume
        } onChange: { [weak self] in
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
    private static func sameFolder(_ left: String, _ right: String) -> Bool {
        guard left.hasPrefix("/"), right.hasPrefix("/") else { return left == right }
        return URL(fileURLWithPath: left).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: right).resolvingSymlinksInPath().standardizedFileURL.path
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
