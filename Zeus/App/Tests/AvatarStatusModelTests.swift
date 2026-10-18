import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct AvatarStatusModelTests {
    private func fixture(quiet: Bool = false) -> (CardStore, AvatarStatusModel, TestClock, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-status-tests-\(UUID())").appendingPathComponent("cards.json")
        let clock = TestClock()
        let cards = CardStore(fileURL: url, clock: { clock.now })
        let status = AvatarStatusModel(cards: cards, clock: { clock.now }, quietHours: { _ in quiet })
        cards.onAdd = { [weak status] in status?.noteNewCard($0) }
        return (cards, status, clock, url)
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func managedBlockSurvivesReadPanelAndSpeechWithoutChangingOrdinaryUnreadRules() {
        let (cards, status, clock, url) = fixture(); defer { cleanup(url) }
        // A mirrored Terminal prompt carries the managed prefix; only those and questions make Zeus wait (FX16).
        let card = Card(id: CardStore.managedActionPrefix + "native", kind: .content, body: "Answer in Terminal", options: [.init(id: "open-terminal", label: "Open in Terminal")], priority: .high)
        cards.add(card)
        status.setOverride(.working, detail: "Other work", progress: nil, ttl: 300)
        status.setManagedBlock("Waiting for you in Terminal")
        cards.markSeen(id: card.id)
        cards.setConversationOpen(true)
        status.notePeek(card, reduceMotion: false)
        #expect(status.state == .alert && status.badgeCount == 0)
        cards.setConversationOpen(false)
        clock.advance(20); status.tick()
        #expect(status.state == .alert)
        status.setManagedBlock(nil)
        #expect(status.state == .working) // Unblocking does not erase unrelated agent status.
        status.setOverride(.alert, detail: "Ordinary alert", progress: nil, ttl: 10)
        #expect(status.state == .waiting) // Read ordinary alerts still clear.
    }

    @Test func transientWinsOverrideForExactlyTwoPointFiveSeconds() {
        let (cards, status, clock, url) = fixture(quiet: true); defer { cleanup(url) }
        status.setOverride(.thinking, detail: "Planning", progress: 0.25, ttl: 10)
        cards.add(Card(kind: .question, body: "new", mood: .happy))
        #expect(status.state == .happy)
        clock.advance(2.499); status.tick()
        #expect(status.state == .happy)
        clock.advance(0.001); status.tick()
        #expect(status.presentation == AvatarPresentation(state: .thinking, detail: "Planning", progress: 0.25))
        #expect(status.openCount == 1)
    }

    @Test func cardWithoutMoodTalksThenAlertsUntilSeen() {
        let (cards, status, clock, url) = fixture(); defer { cleanup(url) }
        let card = Card(kind: .message, body: "new")
        cards.add(card)
        #expect(status.state == .talking)
        clock.advance(2.5); status.tick()
        #expect(status.state == .alert)
        cards.markSeen(id: card.id)
        #expect(status.state == .idle)
    }

    @Test func unseenOverridesWaitingAndQuietHours() {
        let (cards, status, clock, url) = fixture(quiet: true); defer { cleanup(url) }
        let question = Card(kind: .question, body: "question")
        cards.add(question)
        clock.advance(3); status.tick()
        #expect(status.state == .alert)
        cards.markSeen(id: question.id)
        #expect(status.state == .waiting)
        cards.dismiss(id: question.id)
        #expect(status.state == .sleeping)
    }

    @Test func overrideExpiresAtBoundaryAndAutoClearsIt() {
        let (cards, status, clock, url) = fixture(); defer { cleanup(url) }
        let question = Card(kind: .question, body: "question")
        cards.add(question); cards.markSeen(id: question.id)
        clock.advance(3); status.tick()
        status.setOverride(.working, detail: "Building", progress: 1.5, ttl: 5)
        #expect(status.presentation == AvatarPresentation(state: .working, detail: "Building", progress: 1))
        clock.advance(5); status.tick()
        #expect(status.presentation == AvatarPresentation(state: .waiting))
        status.setOverride(.sleeping, detail: nil, progress: nil, ttl: 10)
        #expect(status.state == .sleeping)
        status.clearOverride()
        #expect(status.state == .waiting)
    }

    /// FX16: a present card's actions are optional verdicts; Zeus never waits on them.
    @Test func actionableContentDoesNotCountAsWaiting() {
        let (cards, status, clock, url) = fixture(); defer { cleanup(url) }
        let card = Card(kind: .content, body: "review", options: [CardOption(id: "approve", label: "Approve")])
        cards.add(card); cards.markSeen(id: card.id)
        clock.advance(3); status.tick()
        #expect(status.state == .idle)
        #expect(!cards.hasOpenQuestion)
        cards.respond(id: card.id, response: CardResponse(optionID: "approve", optionLabel: "Approve", device: .mac))
        #expect(status.state == .idle)
        #expect(status.openCount == 0)
    }

    @Test func quietHoursSleepAndIdleIsFinalFallback() {
        let (_, quiet, _, quietURL) = fixture(quiet: true); defer { cleanup(quietURL) }
        #expect(quiet.state == .sleeping)
        let (_, normal, _, normalURL) = fixture(); defer { cleanup(normalURL) }
        #expect(normal.state == .idle)
        quiet.setOverride(.happy, detail: nil, progress: nil, ttl: 0)
        #expect(quiet.state == .sleeping)
    }

    @Test func latestTransientWinsAndDeliveryWarningIsIndependent() {
        let (cards, status, clock, url) = fixture(); defer { cleanup(url) }
        cards.add(Card(kind: .message, body: "first", mood: .happy))
        clock.advance(1)
        cards.add(Card(kind: .message, body: "second", mood: .working))
        status.setDeliveryProblem("Could not reach agent")
        #expect(status.state == .working)
        #expect(status.deliveryProblem == "Could not reach agent")
        #expect(status.openCount == 2)
        clock.advance(2); status.tick()
        #expect(status.state == .working)
        status.setDeliveryProblem(nil)
        #expect(status.deliveryProblem == nil)
    }
}
