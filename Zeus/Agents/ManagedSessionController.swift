import Darwin
import Foundation
import Observation
import ZeusProtocol
import ZeusDesign

/// Owns exactly one tmux pane and its native conversation. Detaching Zeus never kills the agent.
/// Visible samples gate delivery. Consent choices are sent only after an explicit user click.
@MainActor
@Observable
final class ManagedSessionController: ManagedSessionControlling, ManagedSettingsApplying, ManagedPromptAnswering {
    private(set) var managedStatus: ManagedSessionStatus = .off
    private(set) var record: ManagedSessionRecord?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var settingsApplicationAllowed: (() -> Bool)?
    private(set) var managedSettingsApplication: ManagedSettingsApplication?
    private(set) var managedSettingsApplicationError: String?
    var managedAppliedConfiguration: ManagedSessionConfig? { record?.appliedConfiguration }
    var managedCanResumeSettings: Bool { record?.conversation?.didLaunch == true && record?.conversation?.nativeID != nil }
    private var claudeSnapshotExecutable: URL?
    private var claudeSnapshotModified: Date?
    private var claudeSnapshotSupported = false
    func supportsInstructionChangesOnResume(for agent: AgentKind) -> Bool {
        switch agent { case .claude: claudeSnapshotSupported; case .opencode: true; case .codex, .other: false }
    }
    private func refreshInstructionResumeSupport() async {
        guard let executable = executables.agents[.claude] else { claudeSnapshotSupported = false; return }
        let resolved = executable.resolvingSymlinksInPath()
        let modified = try? resolved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard resolved != claudeSnapshotExecutable || modified != claudeSnapshotModified else { return }
        claudeSnapshotExecutable = resolved; claudeSnapshotModified = modified
        let help = try? await FoundationProcessRunner().run(executable: executable, arguments: ["--help"], input: nil, environment: environment)
        claudeSnapshotSupported = help?.status == 0 && help.map { String(decoding: $0.stdout, as: UTF8.self).contains("--system-prompt-snapshot") } == true
    }
    @ObservationIgnored let configuration: () -> ManagedSessionConfig?
    @ObservationIgnored private(set) var executables: ManagedExecutables
    @ObservationIgnored var hosting: (any ManagedSessionHosting)?
    @ObservationIgnored let discoversExecutables: Bool
    @ObservationIgnored let injectedHosting: Bool
    @ObservationIgnored let finder: any ManagedConversationFinding
    @ObservationIgnored let store: ManagedSessionStore
    @ObservationIgnored let bridge: URL
    @ObservationIgnored let bridgeSocket: String
    @ObservationIgnored let environment: [String: String]
    @ObservationIgnored let clock: any RuntimeClock
    @ObservationIgnored let terminalOpener: any ManagedTerminalOpening
    @ObservationIgnored let resourceDirectory: URL?
    @ObservationIgnored let isolatedSocket: String?
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var actions: [Action] = []
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var activation = UUID()
    @ObservationIgnored private var lastConfiguration: ManagedSessionConfig?
    @ObservationIgnored private var sampledLifetime: String?
    @ObservationIgnored private var graceUntil: Date = .distantFuture
    @ObservationIgnored private var blockedCandidate: String?
    @ObservationIgnored private var matchingSamples = 0
    @ObservationIgnored private var hasPaneSample = false
    @ObservationIgnored private var promptEpoch = UUID()
    @ObservationIgnored private var answeringPrompt = false
    private(set) var managedPrompt: ManagedAgentPrompt?
    /// Read-only, ownership-validated visible input, scoped to this process lifetime.
    @ObservationIgnored private(set) var latestInputSample: ManagedInputSample?
    var promptScope: String {
        guard let pane = record?.pane else { return activation.uuidString }
        return [activation.uuidString, promptEpoch.uuidString, record?.owner ?? "", pane.socket, pane.name, pane.id,
                String(pane.serverPID), pane.sessionNumber, String(pane.pid), String(pane.startTime)].joined(separator: "|")
    }
    /// Only a positive idle/working sample proves the dialog was answered.
    var mayResolveBlockedCard: Bool {
        switch managedStatus {
        case .running(let activity): return hasPaneSample && activity != .unknown && blockedCandidate == nil
        case .starting: return false
        case .blocked: return false
        default: return false
        }
    }
    private(set) var blockedDialog: String?
    /// True only after a current, idle screen sample. Startup grace does not permit input.
    var canAcceptInput: Bool { enabled && clock.now >= graceUntil && managedStatus == .running(.idle) && blockedCandidate == nil && !answeringPrompt && managedSettingsApplication?.phase != .applying }
    var isBusy: Bool { operation != nil }
    enum RecoveryRequirement: Equatable { case newConversation }
    /// Native identity is required for resuming a launched conversation.
    var recoveryRequirement: RecoveryRequirement? {
        guard record?.conversation?.didLaunch == true, record?.conversation?.nativeID == nil else { return nil }
        switch managedStatus {
        case .stopped, .failed, .restarting: return .newConversation
        default: return nil
        }
    }
    /// Persisted launch evidence distinguishes a never-started assistant from an exit.
    var hasLaunched: Bool { record?.conversation?.didLaunch == true }
    enum Action: Equatable { case activate, start, stop, restart, fresh, poll, recover, terminal, applySettings }

    /// Injection points keep every test off the human's default server and authentication stores.
    init(configuration: @escaping () -> ManagedSessionConfig?, stateURL: URL, bridge: URL,
         bridgeSocket: String, executables: ManagedExecutables? = nil,
         hosting: (any ManagedSessionHosting)? = nil, finder: any ManagedConversationFinding = NativeManagedConversationFinder(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         clock: any RuntimeClock = SystemRuntimeClock(), terminalOpener: any ManagedTerminalOpening = NativeManagedTerminalOpener(),
         isolatedSocket: String? = nil, resourceDirectory: URL? = Bundle.main.resourceURL) {
        let resolved = executables ?? ManagedExecutables.detect(environment: environment)
        self.discoversExecutables = executables == nil; self.injectedHosting = hosting != nil
        self.configuration = configuration; self.executables = resolved; self.finder = finder
        self.store = .init(url: stateURL); self.bridge = bridge; self.bridgeSocket = bridgeSocket
        self.environment = environment; self.clock = clock; self.terminalOpener = terminalOpener; self.isolatedSocket = isolatedSocket
        self.resourceDirectory = resourceDirectory
        self.hosting = hosting ?? resolved.tmux.map { ManagedTmux(executable: $0, environment: environment, testSocket: isolatedSocket) }
    }
    var enabled: Bool { configuration()?.enabled == true }
    var managedTmuxSessionName: String? { enabled && managedStatus != .off ? record?.pane?.name : nil }
    var managedAttachCommand: String? {
        guard let pane = record?.pane, enabled, managedStatus != .off, let tmux = executables.tmux else { return nil }
        // An explicit socket also works from a nested shell or a different Terminal PATH.
        return "/usr/bin/env -u TMUX -u TMUX_PANE " + Self.shellQuote(tmux.path) + " -u -S " + Self.shellQuote(pane.socket) + " attach -t " + Self.shellQuote(pane.id)
    }
    /// Runtime-effective assistantSessionKey; it never falls back to another agent while enabled.
    var sessionKey: String? {
        guard enabled, let pane = record?.pane, !pane.dead, pane.startTime > 0,
              let conversation = record?.conversation else { return nil }
        switch managedStatus { case .starting, .running, .blocked: break; default: return nil }
        guard let key = record?.confirmedSessionKey, key.hasPrefix(conversation.agent.rawValue + ":"),
              key.hasSuffix("#\(pane.pid).\(pane.startTime)") else { return nil }
        return key
    }
    /// Proves the routing identity with pane namespace + agent parent lifetime, before binding queued input.
    func considerSessions(_ sessions: [ConnectedSession]) {
        guard let pane = record?.pane, !pane.dead, pane.startTime > 0, let conversation = record?.conversation else { return }
        let candidate = sessions.first { session in
            session.agent == conversation.agent && session.tmuxPane == pane.id
                && session.tmuxSocketPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: pane.socket).resolvingSymlinksInPath().path
                && session.sessionKey.hasSuffix("#\(pane.pid).\(pane.startTime)")
                && session.sessionKey.hasPrefix(conversation.agent.rawValue + ":")
        }
        guard let key = candidate?.sessionKey, record?.confirmedSessionKey != key else { return }
        let old = record?.confirmedSessionKey
        record?.confirmedSessionKey = key
        do { try save() }
        catch { record?.confirmedSessionKey = old; setStatus(.failed(reason: error.localizedDescription)) }
    }
    /// Revalidates owner and process lifetime at the transport boundary, after awaits.
    func validateDelivery(to key: String) async throws {
        guard canAcceptInput, sessionKey == key, let pane = record?.pane, let hosting,
              let current = try await hosting.inspect(name: pane.name, owner: record?.owner ?? "", pane: pane),
              current.id == pane.id, !current.dead, current.pid == pane.pid, current.startTime == pane.startTime,
              canAcceptInput, sessionKey == key else { throw ConnectorError.inputBusy }
    }
    /// A single click is authorized for this controller activation and exact pane
    /// lifetime. Shutdown, restart, prompt changes and double-clicks invalidate it.
    func answerManagedPrompt(fingerprint: String, optionID: String) async -> ManagedPromptAnswerResult {
        guard attached, enabled, !answeringPrompt, managedSettingsApplication?.phase != .applying, case .blocked = managedStatus,
              let prompt = managedPrompt, prompt.fingerprint == fingerprint,
              prompt.options.contains(where: { $0.id == optionID }),
              let pane = record?.pane, let hosting, let agent = record?.conversation?.agent else { return .changed }
        answeringPrompt = true; defer { answeringPrompt = false; reconsiderSettingsApplication() }
        let scope = promptScope
        do {
            let result = try await hosting.answerPrompt(pane, owner: record?.owner ?? "", agent: agent, scope: scope,
                fingerprint: fingerprint, optionID: optionID, stillAllowed: { [weak self] in
                    guard let self, self.attached, self.enabled, self.promptScope == scope,
                          self.managedPrompt?.fingerprint == fingerprint, case .blocked = self.managedStatus else { return false }
                    return !self.actions.contains(where: { [.stop, .restart, .fresh, .applySettings].contains($0) })
                })
            if case .answered = result {
                clearBlock()
                // A positive submission receipt invalidates the old question.
                // A repaint must not resurrect it; normal delivery still waits
                // for the next positive idle/working sample.
                setStatus(.running(.unknown))
            }
            return result
        } catch { return .changed }
    }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        refreshExecutables()
        return         executables.agents[agent] == nil ? [] : ManagedAgentLaunch.policies(for: agent).map(\.mode)
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? {
        refreshExecutables()
        guard agent != .other else { return "Choose Claude Code, Codex or OpenCode." }
        return Self.requirementsMessage(missingTmux: executables.tmux == nil, missingAgent: executables.agents[agent] == nil ? agent : nil)
    }
    /// What's missing, in the words Settings uses: an install hint, then the button to press (D3-12).
    static func requirementsMessage(missingTmux: Bool, missingAgent: AgentKind?) -> String? {
        var missing: [String] = []
        if missingTmux { missing.append("tmux (brew install tmux)") }
        if let agent = missingAgent { missing.append("\(agentName(agent)) (the \(agent.rawValue) command)") }
        guard !missing.isEmpty else { return nil }
        return "Not installed: " + missing.joined(separator: " and ") + ". Install \(missing.count == 1 ? "it" : "them"), then press Check Again."
    }
    private func refreshExecutables() {
        guard discoversExecutables else { return }
        executables = .detect(environment: environment)
        if !injectedHosting { hosting = executables.tmux.map { ManagedTmux(executable: $0, environment: environment, testSocket: isolatedSocket) } }
    }
    /// Creates a private, uniquely named assistant folder without altering an existing folder.
    /// The two bundled templates are copied verbatim; a partial creation is removed on failure.
    func createDefaultFolder() throws -> URL {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        guard let resourceDirectory else { throw ManagedSessionError.command("The assistant templates are missing from Zeus.") }
        for suffix in 1...1000 {
            let name = suffix == 1 ? "Zeus Assistant" : "Zeus Assistant \(suffix)"
            let folder = home.appendingPathComponent(name, isDirectory: true)
            if mkdir(folder.path, 0o700) != 0 {
                if errno == EEXIST { continue }
                throw ManagedSessionError.command("Couldn't create the assistant folder: " + String(cString: strerror(errno)))
            }
            do {
                for name in ["AGENTS.md", "CLAUDE.md"] {
                    try FileManager.default.copyItem(at: resourceDirectory.appendingPathComponent(name), to: folder.appendingPathComponent(name))
                }
                return folder
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
        throw ManagedSessionError.command("Couldn't find an unused assistant folder name.")
    }
    func startManagedSession() { enqueue(.start) }
    func stopManagedSession() { cancelManagedSettingsApplication(); enqueue(.stop) }
    func restartManagedSession() { cancelManagedSettingsApplication(); enqueue(.restart) }
    func startNewManagedConversation() { cancelManagedSettingsApplication(); enqueue(.fresh) }
    func openManagedSessionInTerminal() { enqueue(.terminal) }

    func applyManagedSettings(_ config: ManagedSessionConfig) { requestSettings(config, kind: .resume) }
    func switchManagedSettings(_ config: ManagedSessionConfig) { requestSettings(config, kind: .newConversation) }
    func cancelManagedSettingsApplication() { managedSettingsApplication = nil; managedSettingsApplicationError = nil; onChange?() }
    private func requestSettings(_ desired: ManagedSessionConfig, kind: ManagedSettingsApplication.Kind) {
        var config = desired
        guard attached, enabled, config.enabled, record?.conversation?.didLaunch == true else { return }
        var directory: ObjCBool = false
        let id = config.permissionModeID == "default" && config.agent == .claude ? "manual" : config.permissionModeID
        let policies = ManagedAgentLaunch.policies(for: config.agent)
        let problem = managedRequirementsProblem(for: config.agent)
            ?? ((!config.folder.hasPrefix("/") || config.folder.contains("\0") || !FileManager.default.fileExists(atPath: config.folder, isDirectory: &directory) || !directory.boolValue) ? ManagedSessionError.invalidFolder.localizedDescription : nil)
            ?? ((id.map { value in policies.contains { $0.mode.id == value } } ?? policies.contains { $0.mode.isDefault }) ? nil : ManagedSessionError.invalidPermission.localizedDescription)
        guard problem == nil else { managedSettingsApplication = nil; managedSettingsApplicationError = problem; onChange?(); return }
        if kind == .resume, !supportsInstructionChangesOnResume(for: config.agent), let conversation = record?.conversation {
            config.launchPrompt = conversation.launchPrompt
        }
        if kind == .resume, let applied = managedAppliedConfiguration,
           applied.agent == config.agent && applied.folder == URL(fileURLWithPath: config.folder).resolvingSymlinksInPath().standardizedFileURL.path
            && applied.permissionModeID == config.permissionModeID && applied.launchPrompt == config.launchPrompt {
            cancelManagedSettingsApplication(); return
        }
        managedSettingsApplicationError = nil
        if managedSettingsApplication?.configuration == config && managedSettingsApplication?.kind == kind { return }
        managedSettingsApplication = .init(id: UUID(), configuration: config, kind: kind)
        reconsiderSettingsApplication()
        onChange?()
    }
    /// Called after a fresh idle sample or the completion of an in-flight delivery.
    func reconsiderSettingsApplication() {
        guard managedSettingsApplication?.phase == .waiting, canAcceptInput, settingsApplicationAllowed?() != false else { return }
        managedSettingsApplication?.phase = .applying
        enqueue(.applySettings)
    }

    /// Runtime launch adopts a live lease even when automatic startup is disabled.
    func activate() {
        attached = true; activation = UUID(); lastConfiguration = configuration(); enqueue(.activate)
    }
    func configurationChanged() {
        let config = configuration()
        guard config != lastConfiguration else { return }
        let wasEnabled = lastConfiguration?.enabled == true
        lastConfiguration = config
        if !enabled { shutdown() }
        else if !wasEnabled { activate() }
        onChange?()
    }
    /// Leaves the process and ownership lease intact. No SIGTERM/kill-window during app shutdown.
    func shutdown() {
        managedSettingsApplication = nil
        latestInputSample = nil
        sampledLifetime = nil; clearBlock()
        attached = false; activation = UUID(); actions.removeAll()
        monitor?.cancel(); monitor = nil; recovery?.cancel(); recovery = nil
        setStatus(.off)
    }
    /// Owned-pane health and visible-screen tick, also callable deterministically by tests.
    func refresh() { enqueue(.poll) }
    private func enqueue(_ action: Action) {
        guard !actions.contains(action) else { return }
        if action == .start, managedStatus == .starting { return }
        actions.append(action)
        guard operation == nil else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            while !self.actions.isEmpty {
                let action = self.actions.removeFirst()
                do { try await self.perform(action) }
                catch {
                    self.monitor?.cancel(); self.monitor = nil
                    self.recovery?.cancel(); self.recovery = nil
                    self.setStatus(self.attached ? .failed(reason: (error as? ManagedSessionError)?.localizedDescription ?? "Zeus couldn't save or restore your assistant's setup. Check that your Mac has free disk space, then try again.") : .off)
                }
            }
            self.operation = nil
        }
    }
    private func perform(_ action: Action) async throws {
        switch action {
        case .activate:
            guard enabled else { setStatus(.off); return }
            let token = activation
            await refreshInstructionResumeSupport()
            guard attached, enabled, activation == token else { return }
            try load()
            if let pane = try await existingPane(), record?.conversation?.didLaunch == true {
                if pane.dead { try await exited(pane) }
                else { try adopt(pane); try await discoverConversation() }
                return
            }
            if configuration()?.startWhenZeusOpens == true { try await start() }
            else { setStatus(hasLaunched ? .stopped : .off) }
        case .start:
            guard enabled else { setStatus(.off); return }
            attached = true; try load(); record?.restarts = []; try save(); try await start()
        case .stop: try load(); try await stop(); setStatus(enabled ? .stopped : .off)
        case .restart:
            attached = true; try load(); try await stop()
            record?.restarts = []; try save(); try await start()
        case .fresh:
            attached = true; try load()
            do { try await stop() }
            catch ManagedSessionError.ownershipChanged {
                // New conversation is explicit. Leave the now-foreign window alone and allocate another name.
                record?.pane = nil; record?.name = nil
            }
            record?.launchPending = false; record?.pendingWasFresh = false
            record?.confirmedSessionKey = nil; record?.conversation = nil; record?.nativeEnvironment = [:]; record?.restarts = []; try save(); try await start()
        case .poll: guard attached, enabled else { return }; try await poll()
        case .recover:
            guard attached, enabled, case .restarting = managedStatus else { return }
            try await discoverConversation()
            record?.restarts.append(clock.now); try save(); try await start(using: record?.appliedConfiguration)
        case .applySettings:
            let failedRequestID = managedSettingsApplication?.id
            do { try await applySettingsWhenSafe() }
            catch {
                if managedSettingsApplication?.id == failedRequestID {
                    managedSettingsApplication = nil
                    managedSettingsApplicationError = (error as? ManagedSessionError)?.localizedDescription ?? "Zeus couldn't apply your changes. Try again when the assistant is ready."
                }
                if managedStatus != .running(.idle) { throw error }
                onChange?()
            }
        case .terminal:
            guard let command = managedAttachCommand, let pane = record?.pane, let hosting else { return }
            guard try await hosting.inspect(name: pane.name, owner: record?.owner ?? "", pane: pane) != nil else { throw ManagedSessionError.ownershipChanged }
            let directory = store.url.deletingLastPathComponent().appendingPathComponent("managed-launch")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("attach.command")
            try Data(("#!/bin/sh\nexec " + command + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            try await terminalOpener.open(commandFile: file)
        }
    }
    private func load() throws {
        guard !loaded else { return }
        record = try store.load(); loaded = true
    }
    private func save() throws { if let record { try store.save(record); onChange?() } }
    private func setStatus(_ value: ManagedSessionStatus) {
        if managedStatus != value { managedStatus = value; onChange?() }
    }
    private func existingPane() async throws -> ManagedPane? {
        guard let hosting, let record else { return nil }
        if let name = record.name {
            if let pane = try await hosting.inspect(name: name, owner: record.owner, pane: record.pane) {
                if let lease = record.pane, !record.launchPending {
                    guard pane.id == lease.id, pane.socket == lease.socket,
                          pane.serverPID == lease.serverPID, pane.sessionNumber == lease.sessionNumber,
                          pane.pid == lease.pid, pane.dead || pane.startTime == lease.startTime else { throw ManagedSessionError.ownershipChanged }
                }
                try resolvePending(pane); return pane
            }
        }
        let owned = try await hosting.sessions().filter { $0.owner == record.owner }
        guard owned.count <= 1 else { throw ManagedSessionError.command("Zeus found more than one assistant session in Terminal. Close the extra one, then start again.") }
        if let owned = owned.first { return try await hosting.inspect(name: owned.name, owner: record.owner, pane: nil) }
        return nil
    }
    private func resolvePending(_ pane: ManagedPane) throws {
        guard record?.launchPending == true else { return }
        if let old = record?.pane, old.pid == pane.pid, old.startTime == pane.startTime || pane.dead {
            if record?.pendingWasFresh == true { record?.conversation?.didLaunch = false }
        } else { record?.pane = pane }
        record?.launchPending = false; try save()
    }
    private func adopt(_ pane: ManagedPane) throws {
        guard record?.conversation != nil else { throw ManagedSessionError.invalidState }
        if let old = record?.pane, !old.dead, !pane.dead, old.startTime > 0,
           old.pid != pane.pid || old.startTime != pane.startTime { throw ManagedSessionError.ownershipChanged }
        guard pane.startTime > 0 else { throw ManagedSessionError.command("Zeus couldn't start your assistant. Open Terminal to see what happened.") }
        if record?.name != pane.name || record?.pane != pane {
            record?.name = pane.name; record?.pane = pane; try save()
        }
        let lifetime = "\(pane.pid).\(pane.startTime)"
        if sampledLifetime != lifetime {
            latestInputSample = nil
            hasPaneSample = false
            sampledLifetime = lifetime; graceUntil = clock.now.addingTimeInterval(10)
            clearBlock()
            setStatus(attached ? .starting : .off)
        }
        startMonitor()
    }
    private func start(using requested: ManagedSessionConfig? = nil) async throws {
        guard var config = requested ?? configuration(), config.enabled else { setStatus(.off); return }
        try load()
        if let problem = managedRequirementsProblem(for: config.agent) { throw ManagedSessionError.command(problem) }
        let token = activation
        await refreshInstructionResumeSupport()
        guard attached, enabled, activation == token else { return }
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else { throw ManagedSessionError.missingBridge }
        var isDirectory: ObjCBool = false
        guard config.folder.hasPrefix("/"), !config.folder.contains("\0"), FileManager.default.fileExists(atPath: config.folder, isDirectory: &isDirectory), isDirectory.boolValue else { throw ManagedSessionError.invalidFolder }
        let folder = URL(fileURLWithPath: config.folder).resolvingSymlinksInPath().standardizedFileURL.path
        if let conversation = record?.conversation, conversation.agent != config.agent || conversation.folder != folder {
            throw ManagedSessionError.command("Start a new conversation to switch agent or folder. Your current conversation was kept.")
        }
        if let pane = try await existingPane(), !pane.dead, record?.conversation?.didLaunch == true { try adopt(pane); try await discoverConversation(); return }
        monitor?.cancel(); monitor = nil; recovery?.cancel(); recovery = nil; sampledLifetime = nil; clearBlock(); setStatus(.starting)
        if record?.conversation == nil {
            var conversation = ManagedConversation(agent: config.agent, folder: folder, launchPrompt: config.launchPrompt)
            if config.agent == .claude { conversation.nativeID = conversation.nonce }
            record?.conversation = conversation; try save()
        }
        if record?.conversation?.didLaunch == true {
            if supportsInstructionChangesOnResume(for: config.agent) { record?.conversation?.launchPrompt = config.launchPrompt }
            else { config.launchPrompt = record?.conversation?.launchPrompt ?? config.launchPrompt }
        }
        try await discoverConversation()
        guard let conversation = record?.conversation, let executable = executables.agents[conversation.agent], let hosting else { throw ManagedSessionError.invalidState }
        if conversation.didLaunch && conversation.nativeID == nil { throw ManagedSessionError.missingNativeID }
        var pane = try await existingPane()
        if pane == nil {
            if let owned = try await hosting.sessions().first(where: { $0.owner == record?.owner }) {
                record?.name = owned.name; record?.pane = nil; try save()
                pane = try await hosting.create(name: owned.name, owner: record?.owner ?? "", folder: folder)
            }
        }
        if pane == nil {
            for suffix in 1...100 {
                let name = suffix == 1 ? "zeus" : "zeus-\(suffix)"
                let occupied = try await hosting.sessions().contains { $0.name == name }
                if occupied { continue }
                record?.name = name; record?.pane = nil; try save()
                do { pane = try await hosting.create(name: name, owner: record?.owner ?? "", folder: folder); break }
                catch ManagedSessionError.collision { continue }
            }
        }
        guard let pane else { throw ManagedSessionError.command("Zeus couldn't start your assistant. Open Terminal to see what happened.") }
        record?.pane = pane; try save()
        if record?.nativeEnvironment.isEmpty == true {
            let paths = try await hosting.conversationEnvironment(pane, owner: record?.owner ?? "")
            var profiles = environment.filter { ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"].contains($0.key) }
            profiles.merge(paths) { _, serverValue in serverValue }
            record?.nativeEnvironment = profiles.filter { !$0.value.isEmpty }.mapValues {
                URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: folder, isDirectory: true)).standardizedFileURL.path
            }
            try save()
        }
        let launchEnvironment = environment.merging(record?.nativeEnvironment ?? [:]) { _, profile in profile }
        let command = try ManagedAgentLaunch.command(conversation: conversation, permissionID: config.permissionModeID,
            executable: executable, bridge: bridge, socket: bridgeSocket, pane: pane,
            directory: store.url.deletingLastPathComponent().appendingPathComponent("managed-launch"), environment: launchEnvironment,
            systemPromptSnapshotOff: conversation.agent == .claude && claudeSnapshotSupported)
        // Persist the intent before respawn; an interrupted command must not replay the first message.
        record?.pendingWasFresh = !conversation.didLaunch; record?.launchPending = true
        record?.conversation?.didLaunch = true; try save()
        let launched = try await hosting.launch(pane, owner: record?.owner ?? "", command: command, folder: folder)
        record?.name = launched.name; record?.pane = launched; record?.launchPending = false
        config.folder = folder; record?.appliedConfiguration = config; try save()
        if launched.dead { try await exited(launched) }
        else { try adopt(launched); try await discoverConversation() }
    }
    private func discoverConversation() async throws {
        guard let conversation = record?.conversation, conversation.nativeID == nil, conversation.didLaunch else { return }
        let nativeEnvironment = environment.merging(record?.nativeEnvironment ?? [:]) { _, profile in profile }
        do {
            if let id = try await finder.nativeID(for: conversation, environment: nativeEnvironment) {
                record?.conversation?.nativeID = id; try save()
            }
        } catch ManagedSessionError.nativeStoreUnavailable {
            // A new native DB may still be migrating/initializing. Retry metadata ticks;
            // a later restart still refuses to create context if its exact ID remains unknown.
        }
    }
    private func stop() async throws {
        latestInputSample = nil
        setStatus(enabled ? .stopped : .off)
        monitor?.cancel(); monitor = nil; recovery?.cancel(); recovery = nil
        // Stop remains available if a native store is temporarily unreadable. No context is deleted.
        try? await discoverConversation()
        if let pane = try await existingPane(), let hosting {
            if !pane.dead {
                try await hosting.requestExit(pane, owner: record?.owner ?? "")
                let end = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < end {
                    guard let current = try await hosting.inspect(name: pane.name, owner: record?.owner ?? "", pane: pane), !current.dead else { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await hosting.removePane(pane, owner: record?.owner ?? "")
        }
        record?.pane = nil
        // Retain the owned container name, but release the pane lease. Start creates a new window.
        if let hosting, let name = record?.name,
           try await !hosting.sessions().contains(where: { $0.name == name && $0.owner == record?.owner }) { record?.name = nil }
        try save()
    }
    private func poll() async throws {
        guard let pane = record?.pane, let hosting else { return }
        guard let current = try await hosting.inspect(name: pane.name, owner: record?.owner ?? "", pane: pane) else {
            try await exited(nil); return
        }
        if current.dead { try await exited(current) }
        else if current.startTime > 0 {
            try adopt(current); try await discoverConversation()
            let snapshot: ManagedPaneSnapshot
            do { snapshot = try await hosting.capture(current, owner: record?.owner ?? "") }
            catch {
                let latest = try await hosting.inspect(name: current.name, owner: record?.owner ?? "", pane: current)
                if latest == nil || latest?.dead == true { try await exited(latest); return }
                throw error
            }
            guard attached, enabled else { return }
            latestInputSample = .init(pane: current, agent: record?.conversation?.agent ?? .other, snapshot: snapshot, capturedAt: clock.now)
            switch ManagedPaneClassifier.classify(snapshot, agent: record?.conversation?.agent ?? .other) {
            case .blocked(let reason, let dialog):
                let prompt = ManagedPromptParser.parse(snapshot, agent: record?.conversation?.agent ?? .other, scope: promptScope)
                let signature = prompt?.fingerprint ?? reason + "\n" + dialog
                matchingSamples = blockedCandidate == signature ? matchingSamples + 1 : 1
                blockedCandidate = signature
                if clock.now >= graceUntil, matchingSamples >= 2 {
                    hasPaneSample = true; managedPrompt = prompt
                    blockedDialog = prompt.map { [$0.title, $0.detail, $0.question].filter { !$0.isEmpty }.joined(separator: "\n\n") } ?? dialog
                    setStatus(.blocked(reason: reason))
                } else if case .blocked = managedStatus { /* Hold the existing card until the dialog clears. */ }
                else { setStatus(hasPaneSample ? .running(.unknown) : .starting) }
            case .idle, .working:
                guard clock.now >= graceUntil else { setStatus(.starting); return }
                hasPaneSample = true; clearBlock()
                let classification = ManagedPaneClassifier.classify(snapshot, agent: record?.conversation?.agent ?? .other)
                setStatus(.running(classification == .idle ? .idle : .working))
            case .unknown:
                // A blank/repainting capture is not evidence that the human answered a dialog.
                // Reset an unconfirmed candidate; retain a confirmed block until positive evidence.
                blockedCandidate = nil; matchingSamples = 0
                managedPrompt = nil
                if case .blocked = managedStatus { /* Keep the block and its Terminal action. */ }
                else { blockedDialog = nil; setStatus(hasPaneSample ? .running(.unknown) : .starting) }
            }
            if case .blocked = managedStatus { onChange?() }
            if canAcceptInput || managedStatus == .running(.working) || latestInputSample?.draftText != nil { onChange?() }
            reconsiderSettingsApplication()
        }
    }
    private func applySettingsWhenSafe() async throws {
        guard let request = managedSettingsApplication, request.phase == .applying else { return }
        let token = activation
        func stillCurrent() -> Bool {
            attached && enabled && activation == token && managedSettingsApplication?.id == request.id
                && settingsApplicationAllowed?() != false && managedStatus == .running(.idle) && blockedCandidate == nil && !answeringPrompt
        }
        func deferRequest() {
            if managedSettingsApplication?.id == request.id { managedSettingsApplication?.phase = .waiting; onChange?() }
            else { reconsiderSettingsApplication() }
        }
        guard stillCurrent(), let hosting, let pane = try await existingPane(), !pane.dead else { deferRequest(); return }
        try await discoverConversation()
        guard stillCurrent(), let conversation = record?.conversation,
              request.kind == .newConversation || managedCanResumeSettings else { deferRequest(); return }
        var config = request.configuration
        let folder = URL(fileURLWithPath: config.folder).resolvingSymlinksInPath().standardizedFileURL.path
        let changesIdentity = config.agent != conversation.agent || folder != conversation.folder
        guard request.kind == .newConversation || !changesIdentity else {
            cancelManagedSettingsApplication(); return
        }
        let startsNew = request.kind == .newConversation && changesIdentity
        if !startsNew {
            guard managedCanResumeSettings else { deferRequest(); return }
            if !supportsInstructionChangesOnResume(for: config.agent) { config.launchPrompt = conversation.launchPrompt }
            if let applied = managedAppliedConfiguration, applied.permissionModeID == config.permissionModeID && applied.launchPrompt == config.launchPrompt {
                cancelManagedSettingsApplication(); return
            }
        }
        // A probably-idle editor may contain a human draft or Zeus's interrupted
        // paste. Only a positively empty, idle composer is safe to stop.
        let sample = try await hosting.capture(pane, owner: record?.owner ?? "")
        guard stillCurrent(), ManagedPaneClassifier.classify(sample, agent: conversation.agent) == .idle,
              TmuxInputSnapshot(metadata: Data(sample.inputMetadata.utf8), screen: Data(sample.screen.utf8))?.isEmpty == true,
              let current = try await existingPane(), current == pane, stillCurrent() else { deferRequest(); return }
        let finalSample = try await hosting.capture(current, owner: record?.owner ?? "")
        guard stillCurrent(), ManagedPaneClassifier.classify(finalSample, agent: conversation.agent) == .idle,
              TmuxInputSnapshot(metadata: Data(finalSample.inputMetadata.utf8), screen: Data(finalSample.screen.utf8))?.isEmpty == true else { deferRequest(); return }
        do {
            try await stop()
            // Once teardown begins, finish this exact launch even if later edits
            // replace the request. The replacement waits for the new pane to be idle.
            guard attached, enabled, activation == token else { return }
            if startsNew {
                record?.conversation = nil; record?.confirmedSessionKey = nil; record?.nativeEnvironment = [:]
                record?.launchPending = false; record?.pendingWasFresh = false
            }
            record?.restarts = []; try save(); try await start(using: config)
            if managedSettingsApplication?.id == request.id { managedSettingsApplication = nil }
            onChange?()
        } catch {
            if managedSettingsApplication?.id == request.id { managedSettingsApplication = nil }
            throw error
        }
    }
    private func clearBlock() {
        blockedCandidate = nil; matchingSamples = 0; blockedDialog = nil; managedPrompt = nil; promptEpoch = UUID()
    }
    private func exited(_ pane: ManagedPane?) async throws {
        monitor?.cancel(); monitor = nil
        if let pane { record?.pane = pane }
        if pane?.exitStatus == 0 && pane?.signal == nil { try? await discoverConversation(); try save(); setStatus(.stopped); return }
        try await discoverConversation()
        if record?.conversation?.didLaunch == true, record?.conversation?.nativeID == nil {
            setStatus(.failed(reason: ZeusRuntimeCopy.Managed.cantResume(agent: Self.agentName(record?.conversation?.agent ?? .other))))
            return // Never promise a backoff resume when the context cannot be identified.
        }
        record?.restarts.removeAll { clock.now.timeIntervalSince($0) >= 600 }
        try save()
        guard (record?.restarts.count ?? 0) < 5 else {
            setStatus(.failed(reason: "\(Self.agentName(record?.conversation?.agent ?? .other)) quit 5 times in 10 minutes, so Zeus stopped restarting it.")); return
        }
        let count = record?.restarts.count ?? 0
        let deadline = clock.now.addingTimeInterval(count == 0 ? 2 : count == 1 ? 10 : 60)
        setStatus(.restarting(at: deadline))
        let token = activation
        recovery?.cancel()
        recovery = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.attached, self.activation == token, case .restarting = self.managedStatus else { return }
            self.enqueue(.recover)
        }
    }
    private func startMonitor() {
        guard attached, monitor == nil else { return }
        monitor = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(until: clock.now.addingTimeInterval(3)) } catch { return }
                guard let self, self.attached else { return }
                self.refresh()
            }
        }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func agentName(_ agent: AgentKind) -> String {
        switch agent { case .claude: "Claude Code"; case .codex: "Codex"; case .opencode: "OpenCode"; case .other: "Agent" }
    }
}
