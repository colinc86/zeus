import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

// ST1: only the user's assistant may talk to Zeus. Isolated runtime fixtures and defaults; no real tmux, agents or home.

@MainActor @Suite(.serialized) struct ST1AdmissionTests {
    private static let assistant = "claude:/assistant#100.1", other = "codex:/work#200.2"

    private func strictFixture(picked: String? = Self.assistant) throws -> RuntimeFixture {
        let f = try RuntimeFixture()
        f.routing.onlyAssistantMayTalk = true
        f.routing.assistantSessionKey = picked
        f.connect(Self.assistant, channel: true, agent: .claude)
        f.connect(Self.other, channel: false, agent: .codex)
        return f
    }

    @Test func everyToolIsRefusedForANonAssistantSessionAndAllowedForTheAssistant() async throws {
        let f = try strictFixture(); defer { f.stop() }
        for tool in ZeusMCP.tools {
            let refused = await f.call(tool.name, [:], session: Self.other)
            #expect(refused.isError, "\(tool.name)")
            #expect(refused.structured?["error"] == .string(ZeusRuntime.notAssistantText), "\(tool.name)")
            let allowed = await f.call(tool.name, [:], session: Self.assistant)
            #expect(allowed.structured?["error"] != .string(ZeusRuntime.notAssistantText), "\(tool.name)")
        }
        #expect(f.cards.values.isEmpty, "a refused session never touches cards")
    }

    @Test func aRefusedSessionNeverReachesTheThreadAndGetsOneQuietLineADay() async throws {
        let f = try strictFixture(); defer { f.stop() }
        for _ in 0..<3 { _ = await f.call("zeus_say", ["text": "hello from elsewhere"], session: Self.other) }
        #expect(f.cards.values.isEmpty)
        #expect(f.status.state == nil, "no status override from a stranger")
        #expect(f.cards.admissionNotices.count == 1)
        let line = try #require(f.cards.admissionNotices.first)
        #expect(line.summary == "Another session tried to reach Zeus: Codex in /assistant")
        #expect(line.primary.title == "Make it my assistant" && line.primary.doneTitle == "Now your assistant")
        #expect(line.secondary?.title == "Ignore" && line.secondary?.doneTitle == "Ignored")
        // The next day it may say so again, once.
        f.clock.advance(86_400)
        _ = await f.call("zeus_say", ["text": "again"], session: Self.other)
        _ = await f.call("zeus_set_status", ["state": "working"], session: Self.other)
        #expect(f.cards.admissionNotices.count == 2)
        // "Make it my assistant" is the same as picking it in Settings; the session can post from then on.
        line.primary.run()
        #expect(f.routing.assistantSessionKey == Self.other)
        let now = await f.call("zeus_say", ["text": "now allowed"], session: Self.other)
        #expect(!now.isError && f.cards.values.count == 1)
    }

    @Test func theAssistantPostsNormallyAndItsCardsAreUntouchedByRefusals() async throws {
        let f = try strictFixture(); defer { f.stop() }
        let said = await f.call("zeus_say", ["text": "I'm your assistant"], session: Self.assistant)
        #expect(!said.isError && f.cards.values.count == 1)
        guard case .string(let id)? = said.structured?["card_id"] else { Issue.record("no card id"); return }
        let update = await f.call("zeus_update_card", ["card_id": .string(id), "text": "changed by a stranger"], session: Self.other)
        #expect(update.isError && f.cards.card(id: id)?.body == "I'm your assistant")
        let dismiss = await f.call("zeus_dismiss", ["card_id": .string(id)], session: Self.other)
        #expect(dismiss.isError && f.cards.card(id: id)?.status != .dismissed)
    }

    @Test func autoAdoptsTheFirstEligibleSessionAndAnnouncesItOnce() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.onlyAssistantMayTalk = true
        f.routing.preferredAgent = .claude
        f.connect("codex:/elsewhere#1.1", channel: false, agent: .codex)   // wrong backend: never adopted
        f.connect("claude:/first#2.2", channel: true, agent: .claude)
        f.connect("claude:/second#3.3", channel: true, agent: .claude)     // later: not adopted automatically
        #expect(f.routing.adoptedAssistantSessionKey == "claude:/first#2.2")
        #expect(f.runtime.assistantTarget == "claude:/first#2.2")
        #expect(f.cards.admissionNotices.map(\.summary) == ["Talking to Claude in /assistant"])
        #expect(f.cards.admissionNotices.first?.primary.title == "Change" && f.cards.admissionNotices.first?.secondary == nil)
        let first = await f.call("zeus_say", ["text": "hi"], session: "claude:/first#2.2")
        let second = await f.call("zeus_say", ["text": "hi"], session: "claude:/second#3.3")
        #expect(!first.isError && second.isError)
        #expect(f.cards.values.count == 1)
        // Picking a session in Settings replaces what Auto adopted.
        f.routing.assistantSessionKey = "claude:/second#3.3"
        #expect(f.routing.adoptedAssistantSessionKey == nil)
        let now = await f.call("zeus_say", ["text": "hi"], session: "claude:/second#3.3")
        #expect(!now.isError)
    }

    @Test func anySessionModeKeepsTodaysBehaviour() async throws {
        let f = try strictFixture(); defer { f.stop() }
        f.routing.onlyAssistantMayTalk = false
        let posted = await f.call("zeus_say", ["text": "from another agent"], session: Self.other)
        #expect(!posted.isError && f.cards.values.count == 1)
        #expect(f.cards.admissionNotices.isEmpty)
    }

    @Test func theSettingDefaultsToOnlyMyAssistantAndRoundTrips() throws {
        let suite = "zeus-st1-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.whoMayTalk == .assistantOnly && settings.onlyAssistantMayTalk)
        settings.adoptedAssistantSessionKey = "claude:/a#1.1"
        settings.whoMayTalk = .anySession
        #expect(settings.adoptedAssistantSessionKey == nil, "nothing is adopted when everyone may talk")
        #expect(AppSettings(defaults: defaults, userDirectory: nil).whoMayTalk == .anySession)
        settings.whoMayTalk = .assistantOnly
        settings.adoptedAssistantSessionKey = "claude:/a#1.1"
        #expect(AppSettings(defaults: defaults, userDirectory: nil).adoptedAssistantSessionKey == "claude:/a#1.1")
        settings.makeAssistant("codex:/b#2.2")
        #expect(settings.assistantSessionKey == "codex:/b#2.2" && settings.adoptedAssistantSessionKey == nil)
    }

    @Test func theThreadLineHasTwoActionsAndResolvesAsOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-st1-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        var made = 0, ignored = 0
        let notice = AdmissionNotice(id: "refused:x:2026-10-14", createdAt: Date(), summary: "Another session tried to reach Zeus: Codex in ~/work",
                                     primary: .init(title: "Make it my assistant", doneTitle: "Now your assistant") { made += 1 },
                                     secondary: .init(title: "Ignore", doneTitle: "Ignored") { ignored += 1 })
        #expect(store.recordAdmissionNotice(notice))
        #expect(!store.recordAdmissionNotice(notice), "once per id")
        let line = try #require(store.notices.first { $0.id == notice.id })
        #expect(line.kind == .admission && line.actionTitle == "Make it my assistant" && line.secondaryTitle == "Ignore")
        #expect(store.hasNoticeAction(id: notice.id) && store.hasSecondaryNoticeAction(id: notice.id))
        store.performSecondaryNoticeAction(id: notice.id)
        #expect(ignored == 1 && made == 0)
        let done = try #require(store.notices.first { $0.id == notice.id })
        #expect(done.resolvedTitle == "Ignored" && done.secondaryTitle == nil)
        #expect(!store.hasNoticeAction(id: notice.id) && !store.hasSecondaryNoticeAction(id: notice.id))
        #expect(!store.recordAdmissionNotice(notice), "a resolved line is never reopened")
        // "Change" keeps its action after running, so the line stays useful.
        var changes = 0
        let adopted = AdmissionNotice(id: "adopted:y", createdAt: Date(), summary: "Talking to Claude in ~/Zeus",
                                      primary: .init(title: "Change", doneTitle: nil) { changes += 1 }, secondary: nil)
        #expect(store.recordAdmissionNotice(adopted))
        store.performNoticeAction(id: adopted.id)
        #expect(changes == 1 && store.hasNoticeAction(id: adopted.id))
        #expect(store.notices.first { $0.id == adopted.id }?.resolvedTitle == nil)
    }

    @Test func whenZeusRunsTheAssistantOnlyTheManagedSessionMayTalk() async throws {
        let f = try strictFixture(picked: Self.assistant); defer { f.stop() }
        // Zeus runs the assistant: the managed session is the assistant even while Settings still names another one.
        f.routing.managedSession = ManagedSessionConfig(enabled: true, folder: "/assistant", agent: .claude, permissionModeID: nil,
                                                        launchPrompt: "", startWhenZeusOpens: false)
        let picked = await f.call("zeus_say", ["text": "hi"], session: Self.assistant)
        #expect(picked.isError && picked.structured?["error"] == .string(ZeusRuntime.notAssistantText))
        #expect(f.cards.values.isEmpty)
        let line = try #require(f.cards.admissionNotices.last)
        #expect(line.primary.title == "Open Settings" && line.primary.doneTitle == nil, "the managed session stays the assistant")
        #expect(line.secondary?.title == "Ignore")
    }
}
