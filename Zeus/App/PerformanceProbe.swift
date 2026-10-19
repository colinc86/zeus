#if DEBUG || ZEUS_PERFORMANCE_PROBE
import Foundation
import ZeusProtocol

/// Opt-in measurement controls for an isolated perf.sh launch; absent in ordinary Release builds.
/// No input automation or access to the human's running app is involved.
@MainActor
enum PerformanceProbe {
    static var requested: Bool { ProcessInfo.processInfo.environment["ZEUS_PERF_PROBE"] != nil }
    private static var defaultsDomain: String?
    private static let key = MemoryKey()

    static func validatedHome(_ environment: [String: String]) throws -> URL {
        guard environment["ZEUS_PERF_PROBE"] == "1", let home = environment["HOME"],
              environment["CFFIXED_USER_HOME"] == home, ManagedProbeIsolation.canonical(home) == home,
              URL(fileURLWithPath: home).deletingLastPathComponent().path == "/private/tmp",
              URL(fileURLWithPath: home).lastPathComponent.hasPrefix("zperf_"),
              environment["TMUX_TMPDIR"] == home + "/tmux" else { throw Failure.invalidEnvironment }
        _ = try ManagedProbeIsolation.home(environment)
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    /// Even an invalid requested probe constructs only fixture dependencies, then exits at startup.
    static func makeShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellController {
        let name = "test.zeus.performance." + UUID().uuidString
        let home = (try? validatedHome(environment))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // An absolute-path suite keeps the plist in the disposable home; cfprefsd ignores HOME.
        let domain = home.appendingPathComponent("Library/Preferences/" + name).path
        guard let defaults = UserDefaults(suiteName: domain) else { preconditionFailure("Cannot create probe defaults") }
        defaultsDomain = domain
        let preferences = home.appendingPathComponent("Library/Preferences/com.colinc86.Zeus.plist")
        if let data = try? Data(contentsOf: preferences),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            // Not setPersistentDomain: on a path domain removeObject can't clear what it seeds.
            for (key, value) in values { defaults.set(value, forKey: key) }
        }
        // Capture permissions and live workspace content are outside a performance fixture.
        defaults.set(false, forKey: "learn.enabled")
        defaults.removeObject(forKey: "learn.levelPolicies")
        defaults.removeObject(forKey: "learn.rawLevels")
        defaults.set(false, forKey: "learn.screenPermissionRequested")
        defaults.set(false, forKey: "learn.typingPermissionRequested")
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: NoCredentials())
        settings.managedSession = AppSettings.newManagedSession(enabled: false)
        if environment["ZEUS_PERF_MANAGED"] == "1", (try? validatedHome(environment)) != nil {
            settings.managedSession = .init(enabled: true, folder: home.appendingPathComponent("project").path,
                agent: .claude, launchPrompt: "Private idle performance fixture", startWhenZeusOpens: true)
        }
        settings.hasShownWelcome = true
        let support = home.appendingPathComponent("Library/Application Support/Zeus")
        let journal = EncryptedJournalStore(root: support.appendingPathComponent("Journal"), keyProvider: key)
        let rules = try? PersistentRulesStore(fileURL: support.appendingPathComponent("Rules/rules.zrules"), keyProvider: key)
        let services = rules.map { LearningServices(journal: journal, rules: $0, redactor: LocalRedactor(), source: NoCapture()) }
        return ShellController(defaults: defaults, cards: CardStore(fileURL: support.appendingPathComponent("cards.json")),
            settings: settings, learningServices: services, requirePrivateJournal: true)
    }
    static func makeManagedController(settings: AppSettings) throws -> ManagedSessionController? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ZEUS_PERF_MANAGED"] == "1" else { return nil }
        let home = try validatedHome(environment)
        guard let tmux = TmuxExecutable.resolve(), let executable = Bundle.main.executableURL else { throw Failure.invalidEnvironment }
        return ManagedSessionController(configuration: { [weak settings] in settings?.managedSession },
            stateURL: home.appendingPathComponent("managed.json"), bridge: executable.deletingLastPathComponent().appendingPathComponent("zeus-mcp"),
            bridgeSocket: ZeusPaths.bridgeSocket.path,
            executables: .init(tmux: tmux, agents: [.claude: home.appendingPathComponent("idle-claude")]),
            environment: environment, isolatedSocket: home.appendingPathComponent("tmux.sock").path)
    }
    static func makeRatings(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MessageRatingStore {
        let home = try validatedHome(environment)
        return try MessageRatingStore(fileURL: home.appendingPathComponent("Library/Application Support/Zeus/Ratings/ratings.zratings"), keyProvider: key)
    }
    static func cleanup() {
        if let defaultsDomain { UserDefaults(suiteName: defaultsDomain)?.removePersistentDomain(forName: defaultsDomain) }
        defaultsDomain = nil
    }
    private enum Failure: Error { case invalidEnvironment, credentialsDisabled }
    private final class MemoryKey: JournalKeyProviding {
        func key() throws -> Data { Data(repeating: 0x73, count: 32) }
        var requiresProtectedFiles: Bool { false }
    }
    private struct NoCredentials: OpenCodePasswordStoring {
        func read() throws -> String? { nil }
        func save(_ password: String?) throws { throw Failure.credentialsDisabled }
    }
    private final class NoCapture: FocusCaptureSource {
        var isTrusted: Bool { false }
        var isSecure: Bool { true }
        var isLocked: Bool { true }
        var application: FocusApplication? { nil }
        func capture(_ application: FocusApplication) async throws -> FocusRecord? { nil }
    }

    static func start(shell: ShellController) {
        let environment = ProcessInfo.processInfo.environment
        if requested { FileHandle.standardOutput.write(Data("ZEUS_PERF_ISOLATED_READY\n".utf8)) }
        guard environment["ZEUS_PERF_DIAGNOSTICS"] == "1" else { return }
        // perf.sh uses an isolated home. Refuse these controls in an ordinary app launch.
        guard environment["CFFIXED_USER_HOME"] != nil else { return }
        if environment["ZEUS_PERF_IGNORE_OCCLUSION"] == "1" { shell.enableUnoccludedPerformanceProbe() }
        if let rawPhase = environment["ZEUS_PERF_ACTIVITY"], let phase = AgentMessagingHub.PreviewActivity(rawValue: rawPhase), phase != .none {
            shell.messaging.previewEnabled = true
            shell.messaging.previewActivity = phase
            shell.messaging.previewActivityProgress = phase == .working ? 0.4 : nil
        }
        if environment["ZEUS_PERF_LONG_MESSAGE"] == "1", let card = shell.cards.cards.last {
            shell.cards.update(id: card.id) { $0.body = DemoCardKind.longMessageBody }
        }
        if environment["ZEUS_PERF_PANEL"] == "conversation" {
            shell.preparePassivePerformancePanel()
            shell.showTalkPanel()
        }
        if environment["ZEUS_PERF_SCROLL"] == "1" { ScrollBenchmark.start(shell: shell) }
        Task { @MainActor [weak shell] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let shell else { return }
            let activity = shell.surfaceActivity
            let scroll = shell.cardPanelState.viewportForDiagnostics
            let line = "ZEUS_PERF: avatarActive=\(activity.avatar) conversationActive=\(activity.conversation) peekActive=\(activity.peek) settingsActive=\(activity.settings) conversationMounted=\(shell.isConversationMounted) deadlineScheduled=\(shell.scheduledDeadline != nil) assistantActivity=\(shell.messaging.assistantActivity.map { String(describing: $0.phase) } ?? "none") activityRowVisible=\(shell.cardPanelState.activityRowVisibleForDiagnostics) scrollOffset=\(scroll.offset) scrollContent=\(scroll.contentHeight) scrollHeight=\(scroll.height) newestMessageTop=\(shell.cardPanelState.newestMessageTopForDiagnostics.map { String(describing: $0) } ?? "none") \(shell.performanceVisibility)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
#endif
