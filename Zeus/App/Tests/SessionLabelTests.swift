import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class SessionListMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

private func labelledSession(pid: Int32 = 7208, start: UInt64 = 1_791_826_260_000_000,
                             cwd: String = "/work/ParkHub/Zeus", key: String? = nil) -> ConnectedSession {
    ConnectedSession(id: UUID(), sessionKey: key ?? "claude:\(cwd)#\(pid).\(start)", agent: .claude,
                     cwd: cwd, clientName: "Claude Code", supportsChannel: true, tmuxPane: nil,
                     connectedAt: Date(timeIntervalSince1970: 1_791_830_000))
}

@MainActor struct SessionLabelTests {
    @Test func sameFolderLabelsUseAgentProcessPidAndStartRatherThanReconnectTime() throws {
        let first = labelledSession(), second = labelledSession(pid: 7210)
        #expect(SessionLabels.label(for: first).hasPrefix("Claude · ParkHub/Zeus · pid 7208 · started "))
        #expect(SessionLabels.label(for: second).contains("pid 7210"))
        #expect(SessionLabels.label(for: first) != SessionLabels.label(for: second))
        let identity = try #require(SessionLabels.identity(for: first))
        #expect(identity.pid == 7208)
        #expect(identity.startedAt == Date(timeIntervalSince1970: 1_791_826_260))
        #expect(SessionLabels.label(for: first).hasSuffix(identity.startedAt.formatted(date: .omitted, time: .shortened)))
        let reconnected = ConnectedSession(id: UUID(), sessionKey: first.sessionKey, agent: first.agent, cwd: first.cwd,
            clientName: first.clientName, supportsChannel: first.supportsChannel, tmuxPane: first.tmuxPane, connectedAt: .distantFuture)
        #expect(SessionLabels.label(for: reconnected) == SessionLabels.label(for: first))
    }

    @Test func identityHandlesHashesDotsAndColonsInTheDirectoryAndKeepsFullKeysDistinct() throws {
        let first = labelledSession(cwd: "/work/Plan#1.2:now/Zeus#draft")
        #expect(SessionLabels.identity(for: first)?.pid == 7208)
        #expect(SessionLabels.label(for: first).contains("Plan#1.2:now/Zeus#draft"))
        let recycled = labelledSession(start: 1_791_826_261_000_000, cwd: first.cwd)
        #expect(SessionLabels.identity(for: recycled) != SessionLabels.identity(for: first))
        #expect(SessionLabels.unique([first, recycled, first]).map(\.sessionKey) == [first.sessionKey, recycled.sessionKey])
    }

    @Test func malformedAndLegacyKeysNeverExposeAnInventedProcessIdentity() {
        for suffix in ["", "#%3", "#0.1", "#1.0", "#-1.1", "#1.-1", "#1.2.3", "#1.", "#.1", "#1.1x", "#2147483648.1", "#1.18446744073709551616", "#１.1"] {
            let session = labelledSession(key: "claude:/work/ParkHub/Zeus\(suffix)")
            #expect(SessionLabels.identity(for: session) == nil)
            #expect(SessionLabels.label(for: session).hasPrefix("Claude · ParkHub/Zeus · connected "))
        }
        #expect(SessionLabels.identity(for: labelledSession(key: "claude:/a/different/path#7208.123")) == nil)
    }

    @Test func aMissingSavedKeyFallsBackToAutoPersistsAndShowsNoticeUntilAnotherChoice() throws {
        let name = "zeus-session-choice-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let first = labelledSession(), second = labelledSession(pid: 7210)
        settings.assistantSessionKey = first.sessionKey
        settings.reconcileAssistantSession(with: [first, second])
        #expect(settings.assistantSessionKey == first.sessionKey && settings.assistantSessionNotice == nil)
        settings.reconcileAssistantSession(with: [second])
        #expect(settings.assistantSessionKey == nil)
        #expect(settings.assistantSessionNotice == "Saved assistant stopped. Switched to Auto.")
        #expect(defaults.string(forKey: "agent.assistantSessionKey") == nil)
        #expect(AppSettings(defaults: defaults, userDirectory: nil).assistantSessionKey == nil)
        settings.reconcileAssistantSession(with: [])
        #expect(settings.assistantSessionNotice != nil)
        settings.assistantSessionKey = second.sessionKey
        #expect(settings.assistantSessionNotice == nil)
        settings.assistantSessionKey = "claude:/work/ParkHub/Zeus" // Legacy selection cannot match a new process key.
        settings.reconcileAssistantSession(with: [first, second])
        #expect(settings.assistantSessionKey == "claude:/work/ParkHub/Zeus" && settings.assistantSessionNotice == nil)
        settings.assistantSessionKey = nil // Explicitly choosing Auto acknowledges the notice.
        #expect(settings.assistantSessionNotice == nil)
    }

    @Test func shellReconcilesWithoutSettingsOpenAndIgnoresPreviewAndUnavailableRuntime() async throws {
        let name = "zeus-session-observation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let first = labelledSession()
        settings.assistantSessionKey = first.sessionKey
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        defer { shell.stop() }
        shell.observeAssistantSessionSelection()
        #expect(settings.assistantSessionKey == first.sessionKey) // No runtime snapshot yet.
        let runtime = SessionListMessaging()
        runtime.sessions = [first]
        shell.messaging.runtime = runtime
        for _ in 0..<20 { await Task.yield() }
        #expect(settings.assistantSessionKey == first.sessionKey)
        shell.messaging.previewEnabled = true
        for _ in 0..<20 { await Task.yield() }
        runtime.sessions = []
        for _ in 0..<20 { await Task.yield() }
        #expect(settings.assistantSessionKey == first.sessionKey && settings.assistantSessionNotice == nil)
        shell.messaging.previewEnabled = false
        for _ in 0..<20 { await Task.yield() }
        #expect(settings.assistantSessionKey == nil && settings.assistantSessionNotice != nil)
        runtime.sessions = [first]
        for _ in 0..<20 { await Task.yield() }
        settings.assistantSessionKey = first.sessionKey
        for _ in 0..<20 { await Task.yield() }
        runtime.sessions = [labelledSession(pid: 7210)]
        for _ in 0..<20 { await Task.yield() }
        #expect(settings.assistantSessionKey == nil && settings.assistantSessionNotice != nil)
    }
}
