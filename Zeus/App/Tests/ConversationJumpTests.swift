import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct ConversationJumpTests {
    private func entry(_ id: String, user: Bool = false) -> ConversationEntry {
        let card = Card(id: id, kind: user ? .userMessage : .message, body: id)
        return .init(id: "card:\(id)", timestamp: card.createdAt, content: user ? .userMessage(card) : .agentCard(card))
    }
    @Test func unreadAboveAndNewBelowExcludeSeenAndUserRows() {
        let entries = [entry("old"), entry("seen"), entry("user", user: true), entry("visible"), entry("new")]
        let state = ConversationJumpState.make(entries: entries, visible: ["card:visible"], seen: ["seen"], questions: [], atBottom: false, pending: false, awayFromLatest: false)
        #expect(state.unreadAbove == ["old"])
        #expect(state.newBelow == 1 && state.showsLatest)
        let noGeometry = ConversationJumpState.make(entries: entries, visible: [], seen: [], questions: [], atBottom: false, pending: false, awayFromLatest: false)
        #expect(noGeometry == ConversationJumpState())
    }
    @Test func latestUsesOneViewportAndRespectsTallNewestCap() {
        let viewport = ConversationViewport(offset: 100, contentHeight: 1400, height: 300)
        #expect(ConversationJumpState.awayFromLatest(viewport: viewport, newestMessageTop: 800))
        #expect(!ConversationJumpState.awayFromLatest(viewport: viewport, newestMessageTop: 400))
        #expect(!ConversationJumpState.awayFromLatest(viewport: viewport, newestMessageTop: 100))
        let state = ConversationJumpState.make(entries: [entry("seen")], visible: ["card:seen"], seen: ["seen"], questions: [], atBottom: false, pending: false, awayFromLatest: true)
        #expect(state.showsLatest && state.newBelow == 0)
    }
    @Test func sharedCycleSkipsVisibleQuestionsAndWrapsAfterRemoval() {
        let entries = [entry("a"), entry("b"), entry("c")]
        let questions = ["a", "b", "c"]
        var cursor: String?
        for expected in ["a", "c", "a"] {
            let snapshot = ConversationJumpState.make(entries: entries, visible: ["card:b"], seen: [], questions: questions, after: cursor, atBottom: false, pending: false, awayFromLatest: false)
            #expect(snapshot.questionID == expected)
            #expect(snapshot.questionCount == 2)
            #expect(snapshot.questionDirection == (expected == "a" ? .up : .down))
            cursor = ConversationJumpState.nextQuestion(questions: questions, visible: ["card:b"], after: cursor)
            #expect(cursor == snapshot.questionID)
        }
        #expect(ConversationJumpState.nextQuestion(questions: ["b"], visible: ["card:b"], after: "removed") == "b")
    }
    @Test func markUnreadSelectionIsDurableAndFailureDoesNotPublishRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jb1-\(UUID())")
        let url = root.appendingPathComponent("cards.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: url)
        for id in ["old", "visible", "new"] { store.add(Card(id: id, kind: .message, body: id)) }
        store.markSeen(ids: ["old"])
        #expect(CardStore(fileURL: url).seenIDs == ["old"])
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.markSeen(ids: ["visible", "new"])
        #expect(store.seenIDs == ["old"])
        #expect(store.persistenceError != nil)
    }
}
