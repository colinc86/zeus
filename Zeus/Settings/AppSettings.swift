import Foundation
import Observation
import ZeusProtocol
import ZeusSprites
import ZeusDesign

/// User-facing size choice. Each character remains on a whole-point pixel grid.
enum AvatarSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var multiplier: Double {
        switch self { case .small: 0.75; case .medium: 1; case .large: 1.25 }
    }
    func scale(preferred: Int) -> Int { max(2, Int((Double(preferred) * multiplier).rounded())) }
}

/// Settings-backed implementations of the character and routing seams.
@MainActor
@Observable
final class AppSettings: CharacterControlling, AgentRoutingSettings, OpenCodeSessionRouting, OpenCodeDestinationRouting, TmuxTargetRouting {
    var managedSession: ManagedSessionConfig? {
        didSet {
            if oldValue != managedSession { managedAgentInitialized = true }
            if let config = managedSession, let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "agent.managedSession") }
            else { defaults.removeObject(forKey: "agent.managedSession") }
            managedSettingsError = nil
        }
    }
    var managedLaunchedConfig: ManagedSessionConfig? {
        didSet {
            if let config = managedLaunchedConfig, let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "agent.managedLaunchedConfig") }
            else { defaults.removeObject(forKey: "agent.managedLaunchedConfig") }
        }
    }
    let managedConfigurationWasFresh: Bool
    private(set) var managedSettingsError: String?
    var managedAgentInitialized: Bool { didSet { defaults.set(managedAgentInitialized, forKey: "agent.managedAgentInitialized") } }
    static func newManagedSession(enabled: Bool = true) -> ManagedSessionConfig {
        .init(enabled: enabled, folder: "", agent: .claude, permissionModeID: nil,
              launchPrompt: ZeusManagedCopy.defaultLaunchPrompt, startWhenZeusOpens: false)
    }
    private struct OpenCodeSelections: Codable {
        var destinations: [String: OpenCodeDestination] = [:]
        // Display only: legacy IDs cannot authorize HTTP on any server.
        var unverifiedIDs: [String: String] = [:]
    }
    private var openCodeSelections: OpenCodeSelections
    private(set) var sessionLabels: SessionLabelRegistry
    /// Bundled characters plus the user's, reloaded when the Characters folder changes (C1).
    private(set) var availableCharacters: [SpriteCharacter]
    /// Problems in character files, including ones that didn't load. Settings shows them in plain words.
    private(set) var characterProblems: [SpriteIssue]
    /// The user's Characters folder; nil keeps tests away from the real one.
    @ObservationIgnored let userCharacterDirectory: URL?
    @ObservationIgnored private var characterWatcher: CharacterFolderWatcher?
    private var selectedCharacterID: String
    var avatarSize: AvatarSize { didSet { defaults.set(avatarSize.rawValue, forKey: "avatar.size") } }
    var fadeZeusWhenIdle: Bool { didSet { defaults.set(fadeZeusWhenIdle, forKey: "avatar.ghost.enabled") } }
    private var ghostOpacity: Double
    private var ghostDelay: TimeInterval
    private var savedConversationWidth: Double
    var idleOpacity: Double {
        get { ghostOpacity }
        set { ghostOpacity = AvatarGhostState.Configuration.opacity(newValue); defaults.set(ghostOpacity, forKey: "avatar.ghost.opacity") }
    }
    var idleFadeDelay: TimeInterval {
        get { ghostDelay }
        set { ghostDelay = AvatarGhostState.Configuration.delay(newValue); defaults.set(ghostDelay, forKey: "avatar.ghost.delay") }
    }
    var conversationWidth: Double {
        get { savedConversationWidth }
        set {
            savedConversationWidth = newValue.isFinite ? max(Double(ConversationWidth.minimum), newValue.rounded()) : Double(ConversationWidth.minimum)
            defaults.set(savedConversationWidth, forKey: "conversation.width")
        }
    }
    var assistantSessionKey: String? {
        didSet {
            defaults.set(assistantSessionKey, forKey: "agent.assistantSessionKey")
            assistantSessionNotice = nil
            if oldValue != assistantSessionKey { setTmuxTarget(nil, socketPath: nil) }
        }
    }
    private(set) var assistantSessionNotice: String?
    var backend: AssistantBackend {
        didSet {
            defaults.set(backend.rawValue, forKey: "agent.backend")
            if oldValue != backend { deliveryMethod = backend.defaultDeliveryMethod }
        }
    }
    var deliveryMethod: DeliveryMethod { didSet { defaults.set(deliveryMethod.rawValue, forKey: "agent.deliveryMethod") } }
    private struct TmuxDestination: Codable { var pane: String; var socketPath: String }
    private var tmuxDestination: TmuxDestination?
    private var legacyTmuxTarget: String?
    var tmuxTarget: String? {
        get { tmuxDestination?.pane ?? legacyTmuxTarget }
        set {
            tmuxDestination = nil; legacyTmuxTarget = newValue
            defaults.removeObject(forKey: "agent.tmuxDestination")
            defaults.set(newValue, forKey: "agent.tmuxTarget")
        }
    }
    var tmuxTargetSocketPath: String? { tmuxDestination?.socketPath }
    func setTmuxTarget(_ target: String?, socketPath: String?) {
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let socket = Self.normalizedTmuxSocket(socketPath) else { tmuxTarget = nil; return }
        let next = TmuxDestination(pane: target, socketPath: socket)
        guard let data = try? JSONEncoder().encode(next) else { return }
        tmuxDestination = next; legacyTmuxTarget = nil
        defaults.set(data, forKey: "agent.tmuxDestination")
        defaults.removeObject(forKey: "agent.tmuxTarget")
    }
    func revalidateTmuxTarget(socketPath: String?) {
        guard let socket = Self.normalizedTmuxSocket(socketPath), tmuxTarget != nil else { return }
        if tmuxTargetSocketPath != socket { setTmuxTarget(nil, socketPath: nil) }
    }
    static func normalizedTmuxSocket(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        return URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
    }
    func selectedAssistant(in sessions: [ConnectedSession]) -> ConnectedSession? {
        if let key = assistantSessionKey { return sessions.first { $0.sessionKey == key } }
        return automaticAssistant(in: sessions)
    }
    /// The effective Auto choice, even while the user has an explicit selection.
    func automaticAssistant(in sessions: [ConnectedSession]) -> ConnectedSession? {
        let candidates = assistantCandidates(sessions, preservingExplicit: false).filter { preferredAgent == nil || $0.agent == preferredAgent }
        return candidates.first { $0.supportsChannel } ?? candidates.first
    }
    var openCodeURLText: String { didSet { defaults.set(openCodeURLText, forKey: "agent.openCodeBaseURL") } }
    var fontChoice: ZeusFontChoice { didSet { defaults.set(fontChoice.rawValue, forKey: "appearance.font") } }
    var talkHotKey: TalkHotKey {
        didSet { if let data = try? JSONEncoder().encode(talkHotKey) { defaults.set(data, forKey: "general.talkHotKey") } }
    }
    var typewriterEnabled: Bool { didSet { defaults.set(typewriterEnabled, forKey: "general.typewriter") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "general.sound") } }
    /// Play a sound when the peek bubble pops up. Off by default: it's opt-in, like the typewriter blip.
    var popupSoundEnabled: Bool { didSet { defaults.set(popupSoundEnabled, forKey: "general.popupSound") } }
    var popupSound: PopupSound { didSet { defaults.set(popupSound.rawValue, forKey: "general.popupSoundName") } }
    var hasShownWelcome: Bool { didSet { defaults.set(hasShownWelcome, forKey: "general.welcomeShown") } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "quiet.enabled") } }
    var quietStartHour: Int { didSet { defaults.set(quietStartHour, forKey: "quiet.startHour") } }
    var quietEndHour: Int { didSet { defaults.set(quietEndHour, forKey: "quiet.endHour") } }
    @ObservationIgnored private let passwordStore: any OpenCodePasswordStoring
    private(set) var passwordError: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, userDirectory: URL? = ZeusPaths.userCharacters, passwordStore: any OpenCodePasswordStoring = OpenCodePasswordStore()) {
        self.passwordStore = passwordStore
        self.defaults = defaults
        managedLaunchedConfig = defaults.data(forKey: "agent.managedLaunchedConfig").flatMap { try? JSONDecoder().decode(ManagedSessionConfig.self, from: $0) }
        managedAgentInitialized = defaults.bool(forKey: "agent.managedAgentInitialized")
        if let saved = defaults.object(forKey: "agent.managedSession") {
            managedConfigurationWasFresh = false
            managedAgentInitialized = true
            if let data = saved as? Data, let config = try? JSONDecoder().decode(ManagedSessionConfig.self, from: data) { managedSession = config }
            else {
                managedSession = Self.newManagedSession(enabled: false)
                managedSettingsError = "Couldn't read your saved assistant settings. Choose an agent and folder again before starting."
            }
        } else {
            // A connected session or old routing preference isn't a setup-mode choice.
            // Keep those preferences, but lead with the managed setup until explicitly changed.
            managedConfigurationWasFresh = true
            managedSession = Self.newManagedSession()
        }
        if let data = defaults.data(forKey: "agent.openCodeDestinations") {
            openCodeSelections = (try? JSONDecoder().decode(OpenCodeSelections.self, from: data)) ?? .init()
        } else {
            let legacy = (defaults.dictionary(forKey: "agent.openCodeSelections") as? [String: String] ?? [:])
                .filter { $0.key.hasPrefix("opencode:") && OpenCodeNativeSession.validID($0.value) }
            openCodeSelections = .init(unverifiedIDs: legacy)
        }
        sessionLabels = defaults.data(forKey: "agent.sessionLabels").flatMap { try? JSONDecoder().decode(SessionLabelRegistry.self, from: $0) } ?? SessionLabelRegistry()
        userCharacterDirectory = userDirectory
        let library = CharacterLibrary.load(userDirectory: userDirectory)
        availableCharacters = library.characters
        characterProblems = library.problems
        selectedCharacterID = Self.characterID(saved: defaults.string(forKey: "character.id"), in: library)
        avatarSize = AvatarSize(rawValue: defaults.string(forKey: "avatar.size") ?? "") ?? .medium
        fadeZeusWhenIdle = defaults.bool(forKey: "avatar.ghost.enabled")
        ghostOpacity = AvatarGhostState.Configuration.opacity((defaults.object(forKey: "avatar.ghost.opacity") as? Double) ?? 0.3)
        ghostDelay = AvatarGhostState.Configuration.delay((defaults.object(forKey: "avatar.ghost.delay") as? Double) ?? 30)
        let width = (defaults.object(forKey: "conversation.width") as? Double) ?? Double(ConversationWidth.minimum)
        savedConversationWidth = width.isFinite ? max(Double(ConversationWidth.minimum), width.rounded()) : Double(ConversationWidth.minimum)
        assistantSessionKey = defaults.string(forKey: "agent.assistantSessionKey")
        let backend = AssistantBackend(rawValue: defaults.string(forKey: "agent.backend") ?? "") ?? .claude
        self.backend = backend
        deliveryMethod = DeliveryMethod(rawValue: defaults.string(forKey: "agent.deliveryMethod") ?? "") ?? backend.defaultDeliveryMethod
        let savedDestination = defaults.data(forKey: "agent.tmuxDestination").flatMap { try? JSONDecoder().decode(TmuxDestination.self, from: $0) }
        if let saved = savedDestination, let socket = Self.normalizedTmuxSocket(saved.socketPath) { tmuxDestination = .init(pane: saved.pane, socketPath: socket) }
        else { tmuxDestination = nil }
        legacyTmuxTarget = defaults.string(forKey: "agent.tmuxTarget")
        openCodeURLText = defaults.string(forKey: "agent.openCodeBaseURL") ?? "http://127.0.0.1:4096"
        fontChoice = ZeusFontChoice(rawValue: defaults.string(forKey: "appearance.font") ?? "") ?? .pixel
        if let data = defaults.data(forKey: "general.talkHotKey"), let shortcut = try? JSONDecoder().decode(TalkHotKey.self, from: data), (shortcut.isValid || !shortcut.enabled) {
            talkHotKey = shortcut
        } else { talkHotKey = TalkHotKey() }
        typewriterEnabled = defaults.object(forKey: "general.typewriter") == nil ? true : defaults.bool(forKey: "general.typewriter")
        soundEnabled = defaults.bool(forKey: "general.sound")
        popupSoundEnabled = defaults.bool(forKey: "general.popupSound")
        popupSound = defaults.string(forKey: "general.popupSoundName").flatMap(PopupSound.init(rawValue:)) ?? .chime
        hasShownWelcome = defaults.bool(forKey: "general.welcomeShown")
        quietHoursEnabled = defaults.bool(forKey: "quiet.enabled")
        quietStartHour = Self.hour(defaults, key: "quiet.startHour", fallback: 22)
        quietEndHour = Self.hour(defaults, key: "quiet.endHour", fallback: 7)
    }

    /// Consume onboarding once without adding a synthetic message ahead of the agent's check-in.
    func consumeManagedOnboarding(hasHistory: Bool, isHidden: Bool) -> Bool {
        guard !hasShownWelcome, !hasHistory, !isHidden, managedSettingsError == nil,
              let config = managedSession, config.enabled, config.folder.isEmpty else { return false }
        // Persist the chosen mode before the welcome marker makes a future launch look like a legacy setup.
        managedSession = config
        hasShownWelcome = true
        return true
    }

    var currentCharacterID: String {
        get { selectedCharacterID }
        set {
            guard availableCharacters.contains(where: { $0.id == newValue }) else { return }
            selectedCharacterID = newValue
            defaults.set(newValue, forKey: "character.id")
        }
    }
    var currentCharacter: SpriteCharacter? { availableCharacters.first { $0.id == currentCharacterID } }

    /// The saved choice if it loaded, else Zeus. The saved choice itself is kept, so a character that disappears for
    /// a moment (an editor saving by replacing the file) comes back when it reappears.
    private static func characterID(saved: String?, in library: CharacterLibrary) -> String {
        library.characters.first { $0.id == saved }?.id
            ?? library.character(id: CharacterLibrary.defaultCharacterID)?.id ?? library.characters.first?.id ?? CharacterLibrary.defaultCharacterID
    }

    /// Reloads bundled and user characters. Unchanged characters keep their identity, so the current one keeps
    /// playing; an edited current one re-renders in place; a removed one falls back to Zeus.
    func reloadCharacters() {
        let library = CharacterLibrary.load(userDirectory: userCharacterDirectory)
        func key(_ list: [SpriteCharacter]) -> [String] { list.map { "\($0.id)#\($0.fingerprint)" } }
        if key(library.characters) != key(availableCharacters) { availableCharacters = library.characters }
        if library.problems != characterProblems { characterProblems = library.problems }
        let id = Self.characterID(saved: defaults.string(forKey: "character.id"), in: library)
        if id != selectedCharacterID { selectedCharacterID = id }
    }

    /// Starts reloading characters whenever a file in the Characters folder changes (creating the folder if needed).
    func startWatchingCharacters() {
        guard characterWatcher == nil, let directory = userCharacterDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        characterWatcher = CharacterFolderWatcher(directory: directory) { [weak self] in self?.reloadCharacters() }
        reloadCharacters()
    }

    func stopWatchingCharacters() {
        characterWatcher?.stop()
        characterWatcher = nil
    }
    var pixelScale: Int { scale(for: currentCharacterID) }
    func scale(for id: String) -> Int { avatarSize.scale(preferred: availableCharacters.first { $0.id == id }?.preferredScale ?? 4) }

    func openCodeDestination(for sessionKey: String) -> OpenCodeDestination? { openCodeSelections.destinations[sessionKey] }
    func openCodeSessionID(for sessionKey: String) -> String? { openCodeDestination(for: sessionKey)?.sessionID }

    /// Display-only identity includes legacy choices, which never authorize delivery.
    func savedOpenCodeSessionID(for sessionKey: String) -> String? {
        openCodeSessionID(for: sessionKey) ?? openCodeSelections.unverifiedIDs[sessionKey]
    }
    func openCodeSelectionNotice(for sessionKey: String) -> String? {
        if let destination = openCodeDestination(for: sessionKey) {
            if openCodeBaseURL.flatMap(OpenCodeDestination.canonicalEndpoint) != destination.endpoint {
                return ZeusRuntimeCopy.OpenCode.otherServerNotice(destination.endpoint.absoluteString)
            }
        } else if openCodeSelections.unverifiedIDs[sessionKey] != nil {
            return ZeusRuntimeCopy.OpenCode.chooseAgainNotice
        }
        return nil
    }

    /// Save the chosen ID and its current canonical endpoint together before publishing.
    /// URL edits never mutate this record; choosing again explicitly replaces it.
    @discardableResult func setOpenCodeSessionID(_ id: String?, for sessionKey: String) -> Bool {
        guard sessionKey.hasPrefix("opencode:") else { return false }
        var next = openCodeSelections
        if let id {
            guard OpenCodeNativeSession.validID(id), let endpoint = openCodeBaseURL,
                  let destination = OpenCodeDestination(sessionID: id, endpoint: endpoint) else { return false }
            next.destinations[sessionKey] = destination
        } else { next.destinations.removeValue(forKey: sessionKey) }
        next.unverifiedIDs.removeValue(forKey: sessionKey)
        guard let data = try? JSONEncoder().encode(next) else { return false }
        defaults.set(data, forKey: "agent.openCodeDestinations")
        openCodeSelections = next
        return true
    }

    /// Unmapped OpenCode bridges share a folder connection; mapped destinations remain distinct.
    func assistantCandidates(_ sessions: [ConnectedSession], preservingExplicit: Bool = true) -> [ConnectedSession] {
        let unique = SessionLabels.unique(sessions)
        var folders: Set<String> = []
        return unique.filter { session in
            guard session.agent == .opencode, openCodeSessionID(for: session.sessionKey) == nil else { return true }
            guard folders.insert(session.cwd).inserted else { return false }
            return true
        }.map { representative in
            guard preservingExplicit, representative.agent == .opencode, openCodeSessionID(for: representative.sessionKey) == nil,
                  let selected = assistantSessionKey,
                  let pinned = unique.first(where: { $0.sessionKey == selected && $0.agent == .opencode && $0.cwd == representative.cwd }),
                  openCodeSessionID(for: pinned.sessionKey) == nil else { return representative }
            return pinned
        }
    }

    func updateSessionLabels(_ sessions: [ConnectedSession]) {
        var next = sessionLabels
        next.sync(sessions)
        guard next != sessionLabels else { return }
        sessionLabels = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: "agent.sessionLabels") }
    }

    func pruneSessionLabels(keeping keys: Set<String>) {
        var next = sessionLabels
        next.retain(keys)
        guard next != sessionLabels else { return }
        sessionLabels = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: "agent.sessionLabels") }
    }

    var preferredAgent: AgentKind? { AgentKind(rawValue: backend.rawValue) }

    /// Drops an obsolete process selection once the live runtime supplies its session list.
    func reconcileAssistantSession(with sessions: [ConnectedSession], isDead: (String) -> Bool = AgentSessionLiveness.isDead) {
        guard let selected = assistantSessionKey, !sessions.contains(where: { $0.sessionKey == selected }), isDead(selected) else { return }
        assistantSessionKey = nil
        assistantSessionNotice = "Saved assistant stopped. Switched to Auto."
    }
    var openCodeServerPassword: String? {
        do { return try passwordStore.read() }
        catch { passwordError = error.localizedDescription; return nil }
    }
    @discardableResult func saveOpenCodePassword(_ password: String?) -> Bool {
        do { try passwordStore.save(password); passwordError = nil; return true }
        catch { passwordError = error.localizedDescription; return false }
    }

    var openCodeBaseURL: URL? {
        let text = openCodeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    var openCodeURLValidationMessage: String? {
        if let url = URL(string: openCodeURLText.trimmingCharacters(in: .whitespacesAndNewlines)), url.user != nil || url.password != nil {
            return "Remove the username and password from the URL. Save the server password in the Keychain field below."
        }
        return openCodeBaseURL == nil ? "Enter an HTTP or HTTPS server URL, such as http://127.0.0.1:4096." : nil
    }

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietStartHour == quietEndHour { return true }
        if quietStartHour < quietEndHour { return hour >= quietStartHour && hour < quietEndHour }
        return hour >= quietStartHour || hour < quietEndHour
    }

    /// Calendar matching preserves local quiet-hour boundaries across DST transitions.
    func nextQuietBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        guard quietHoursEnabled, quietStartHour != quietEndHour else { return nil }
        return [quietStartHour, quietEndHour].compactMap {
            calendar.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0, second: 0),
                              matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }.min()
    }

    private static func hour(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(23, max(0, defaults.integer(forKey: key)))
    }
}
