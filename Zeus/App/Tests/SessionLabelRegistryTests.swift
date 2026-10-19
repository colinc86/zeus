import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct SessionLabelRegistryTests {
    private func session(_ pid: Int, cwd: String = "/work/Zeus") -> ConnectedSession {
        .init(id: UUID(), sessionKey: "claude:\(cwd)#\(pid).1000000", agent: .claude, cwd: cwd, clientName: nil,
              supportsChannel: false, tmuxPane: nil, connectedAt: Date(timeIntervalSince1970: Double(pid)))
    }
    @Test func ordinalsSurviveDisconnectReloadAndReconnectWithoutRenamingHistory() throws {
        let suite = TestDefaults.suite("zeus-label-registry")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let a = session(1), b = session(2), c = session(3)
        settings.updateSessionLabels([b, a])
        #expect(settings.sessionLabels.label(a.sessionKey) == "Claude · Zeus")
        #expect(settings.sessionLabels.label(b.sessionKey) == "Claude · Zeus · 2")
        settings.updateSessionLabels([b, c])
        #expect(settings.sessionLabels.label(c.sessionKey) == "Claude · Zeus · 3")
        #expect(settings.sessionLabels.label(a.sessionKey) == "Claude · Zeus")
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        restored.updateSessionLabels([b, a, c])
        #expect(Set([a,b,c].map { restored.sessionLabels.label($0.sessionKey) }).count == 3)
        restored.pruneSessionLabels(keeping: [b.sessionKey])
        restored.updateSessionLabels([b, session(4)])
        #expect(restored.sessionLabels.label(session(4).sessionKey) == "Claude · Zeus")
        #expect(restored.sessionLabels.label(b.sessionKey) == "Claude · Zeus · 2")
    }
    @Test func sameBasenamesExpandTogetherAndStayStableAfterDisconnect() {
        let a = session(1, cwd: "/ParkHub/Zeus"), b = session(2, cwd: "/Archive/Zeus")
        var registry = SessionLabelRegistry()
        registry.sync([a]); #expect(registry.label(a.sessionKey) == "Claude · Zeus")
        registry.sync([b, a]); #expect(registry.label(a.sessionKey) == "Claude · ParkHub/Zeus")
        #expect(registry.label(b.sessionKey) == "Claude · Archive/Zeus")
        registry.sync([]); #expect(registry.label(a.sessionKey) == "Claude · ParkHub/Zeus")
        #expect(SessionLabelRegistry().label(a.sessionKey) == "Claude · Zeus")
        #expect(SessionLabelRegistry().label("claude:/work/notes#draft#%3") == "Claude · notes#draft · pane 3")
    }
    @Test func deepWorktreeSuffixesRemainDistinctAcrossHistoryAndReload() throws {
        let a = session(1, cwd: "/tmp/A/.worktrees/worker")
        let b = session(2, cwd: "/tmp/B/.worktrees/worker")
        let c = session(3, cwd: a.cwd)
        let short = session(4, cwd: "/worker")
        var registry = SessionLabelRegistry()
        registry.sync([c, b, a, short])
        #expect(registry.label(a.sessionKey) == "Claude · A/.worktrees/worker")
        #expect(registry.label(b.sessionKey) == "Claude · B/.worktrees/worker")
        #expect(registry.label(c.sessionKey) == "Claude · A/.worktrees/worker · 2")
        #expect(registry.label(short.sessionKey) == "Claude · /worker")
        let labels = [a,b,c,short].map { registry.label($0.sessionKey) }
        #expect(Set(labels).count == 4)
        var restored = try JSONDecoder().decode(SessionLabelRegistry.self, from: JSONEncoder().encode(registry))
        restored.sync([b])
        #expect([a,b,c,short].map { restored.label($0.sessionKey) } == labels)
    }

    @Test func dividerBeforeAUserBubbleRestartsTheAgentLabel() {
        let t = Date(timeIntervalSince1970: 1791820800)
        let a = Card(id: "a", kind: .message, body: "A", sessionKey: "claude:/a", createdAt: t)
        let b = Card(id: "b", kind: .message, body: "B", sessionKey: "claude:/a", createdAt: t.addingTimeInterval(702))
        let c = Card(id: "c", kind: .message, body: "C", sessionKey: "codex:/a", createdAt: t.addingTimeInterval(703))
        let entry: (Card) -> ConversationEntry = { .init(id: "card:\($0.id)", timestamp: $0.createdAt, content: .agentCard($0)) }
        let user = ConversationEntry(id: "answer:a", timestamp: t.addingTimeInterval(701), content: .userAnswer(cardID: a.id, response: .init(text: "Reply", device: .mac)))
        #expect(ConversationLayout.sessionLabelEntries([entry(a), user, entry(b), entry(c)], cards: [a,b,c]) == ["card:a", "card:b", "card:c"])
    }
}
