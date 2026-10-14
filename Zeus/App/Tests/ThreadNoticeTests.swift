import Foundation
import Testing
@testable import Zeus

// Quiet app-owned thread lines (L1; shared with AC2's app changes). Each test uses its own temporary history file.

@MainActor @Suite struct ThreadNoticeTests {
    private func store() -> (CardStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-notice-\(UUID()).json")
        return (CardStore(fileURL: url), url)
    }

    @Test func noticePersistsWithoutItsActionAndNeverBadges() throws {
        let (cards, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        var ran = 0
        let notice = ThreadNotice(kind: .appChange, createdAt: Date(timeIntervalSince1970: 1_800_000_000), summary: "Switched to Wisp", actionTitle: "Undo")
        let recorded = cards.recordNotice(notice, action: { ran += 1 }, doneTitle: "Undone")
        #expect(recorded)
        #expect(cards.unseenCount == 0 && cards.hasNoticeAction(id: notice.id))
        cards.performNoticeAction(id: notice.id)
        cards.performNoticeAction(id: notice.id)
        #expect(ran == 1 && cards.notices.first?.resolvedTitle == "Undone" && !cards.hasNoticeAction(id: notice.id))

        let reloaded = CardStore(fileURL: url)
        #expect(reloaded.notices == cards.notices)
        #expect(!reloaded.hasNoticeAction(id: notice.id), "closures never survive a relaunch")
    }

    @Test func noticesJoinTheThreadInTimeOrderAndClearWithIt() throws {
        let (cards, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        cards.add(.init(id: "c_a", kind: .message, body: "Hello", createdAt: t, updatedAt: t))
        cards.recordNotice(ThreadNotice(id: "n_1", kind: .learning, createdAt: t.addingTimeInterval(60), summary: "Sent your daily summary",
                                        actionTitle: "View", detail: "Zeus's summary"))
        let model = ConversationModel(cards: cards, messaging: AgentMessagingHub())
        #expect(model.thread.map(\.id) == ["card:c_a", "notice:n_1"])
        #expect(model.thread.last?.isNotice == true && model.thread.last?.isUser == false)
        #expect(ConversationLayout.unseenBelow(entries: model.thread, visible: ["card:c_a"], seen: ["c_a"]) == 0)
        #expect(!ConversationLayout.grouped(model.thread[1], after: model.thread[0], cards: cards.cards))
        #expect(cards.removeNotices(kind: .learning) && cards.notices.isEmpty)
    }

    @Test func historyWithoutNoticesStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-notice-old-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"cards":[],"seenIDs":[]}"#.utf8).write(to: url)
        let cards = CardStore(fileURL: url)
        #expect(cards.persistenceError == nil && cards.notices.isEmpty)
    }
}
