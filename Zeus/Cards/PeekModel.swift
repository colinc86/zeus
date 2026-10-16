import Foundation
import Observation
import ZeusDesign
import ZeusProtocol

/// Peek state is ephemeral; cards and answers always live in CardStore.
@MainActor @Observable
final class PeekModel {
    enum OpenAction { case message, reply, more }
    struct Expansion: Equatable {
        let cardID: String
        let reply: Bool
    }
    struct Suppression: Equatable {
        var panelOpen = false
        var hidden = false
        var quiet = false
        var focused: Bool? = nil
        var allowsPeek: Bool { !panelOpen && !hidden && !quiet && focused != true }
    }

    private var cardID: String?
    /// Read the durable card live so content/options and layout observation follow updates.
    var card: Card? { cardID.flatMap { store.card(id: $0) } }
    private(set) var isVisible = false
    private(set) var types = false
    private(set) var isTyping = false
    private(set) var startedAt: Date = .distantPast
    private(set) var answerError: String?
    private(set) var answeredOptionID: String?
    private(set) var hovering = false
    private(set) var arrivals: [String] = []
    @ObservationIgnored private var arrivalIDs: Set<String> = []
    private var typingEndsAt = Date.distantPast
    private var deadline: Date?
    private var remaining: TimeInterval?
    private var receiptDeadline: Date?
    @ObservationIgnored private let store: CardStore
    @ObservationIgnored private let clock: () -> Date

    init(store: CardStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    var nextDeadline: Date? {
        guard isVisible else { return nil }
        return [isTyping ? typingEndsAt : nil, receiptDeadline ?? deadline].compactMap { $0 }.min()
    }

    static func eligible(_ card: Card) -> Bool { [.message, .question, .content].contains(card.kind) && !card.isRatingHeld }
    private var unseenEligibleIDs: Set<String> {
        let seen = store.seenIDs
        return Set(store.cards.lazy.filter { Self.eligible($0) && !seen.contains($0.id) }.map(\.id))
    }
    var moreCount: Int {
        let eligible = unseenEligibleIDs, current = cardID
        return arrivals.lazy.filter { $0 != current && eligible.contains($0) }.count
    }
    var oldestUnseenID: String? {
        let eligible = unseenEligibleIDs
        return arrivals.first { eligible.contains($0) }
    }

    /// Called after successful retention/clear; unseen arrivals still in history keep their order.
    func pruneRetainedHistory() {
        let retained = Set(store.cards.map(\.id))
        let next = arrivals.filter { retained.contains($0) }
        if next != arrivals { arrivals = next }
        arrivalIDs.formIntersection(retained)
        if let cardID, !retained.contains(cardID) { self.cardID = nil; close() }
    }

    /// Returns true only when this new arrival should be spoken. Suppressed arrivals are never replayed.
    @discardableResult func receive(_ newCard: Card, suppression: Suppression, reduceMotion: Bool, typewriter: Bool) -> Bool {
        guard Self.eligible(newCard), newCard.status == .open, arrivalIDs.insert(newCard.id).inserted else { return false }
        arrivals.append(newCard.id)
        guard suppression.allowsPeek else { close(); return false }
        cardID = newCard.id
        types = store.markRevealed(id: newCard.id) && typewriter && !reduceMotion
        isTyping = types
        startedAt = clock()
        answerError = nil
        answeredOptionID = nil
        receiptDeadline = nil
        isVisible = true
        let typing = !types ? 0 : ZeusPeekTiming.typingDuration(length: ZeusPeekTiming.typedLength(newCard.body))
        let delay = ZeusPeekTiming.autoHideDelay(words: ZeusPeekTiming.wordCount(title: newCard.title, body: newCard.body), highPriority: newCard.priority == .high)
        typingEndsAt = startedAt.addingTimeInterval(typing)
        remaining = hovering ? delay : nil
        deadline = hovering ? nil : delay.map { typingEndsAt.addingTimeInterval($0) }
        return true
    }

    func setHovering(_ hover: Bool) {
        guard hover != hovering else { return }
        hovering = hover
        guard isVisible, answeredOptionID == nil else { return }
        if hover {
            remaining = deadline.map { max(0, $0.timeIntervalSince(max(clock(), typingEndsAt))) }
            deadline = nil
        } else {
            deadline = remaining.map { max(clock(), typingEndsAt).addingTimeInterval(max($0, ZeusPeekTiming.minimumAfterHover)) }
            remaining = nil
        }
    }

    /// A close click is an interaction; timeout and suppression deliberately do not mark seen.
    func close(markSeen: Bool = false) {
        if markSeen, let card { store.markSeen(id: card.id) }
        isVisible = false
        isTyping = false
        deadline = nil
        remaining = nil
        receiptDeadline = nil
        hovering = false
    }

    func panelOpened() { close(); arrivals.removeAll(); arrivalIDs.removeAll() }

    func tick(suppression: Suppression) {
        guard isVisible else { return }
        guard suppression.allowsPeek else { close(); return }
        if isTyping, clock() >= typingEndsAt {
            isTyping = false
        }
        if let receiptDeadline {
            if clock() >= receiptDeadline { close() }
            return
        }
        guard let card, store.card(id: card.id)?.status == .open else { close(); return }
        if let deadline, clock() >= deadline { close() }
    }

    /// Successful direct answers get a brief checkmark receipt even for high-priority/hovered peeks.
    @discardableResult func answer(optionID: String) -> Bool {
        guard isVisible, answeredOptionID == nil, let card,
              let option = card.options.first(where: { $0.id == optionID }), card.options.count <= ZeusPeekTiming.maxInlineOptions else { return false }
        guard store.respond(id: card.id, response: CardResponse(optionID: option.id, optionLabel: option.label, respondedAt: clock(), device: .mac)) else {
            answerError = store.persistenceError.map { "Could not save your reply. \($0) Try again." } ?? "This question is no longer open. Open the conversation to continue."
            return false
        }
        answerError = nil
        // App-local actions (such as Open in Terminal) leave their card open without an answer.
        // The runtime handles them synchronously; they must not show an answer receipt or close the peek.
        if let current = store.card(id: card.id), current.status == .open, current.response == nil { return true }
        isTyping = false
        answeredOptionID = option.id
        deadline = nil
        remaining = nil
        receiptDeadline = clock().addingTimeInterval(0.6)
        return true
    }

    func expand(_ action: OpenAction) -> Expansion? {
        guard isVisible, let card else { return nil }
        let target = action == .more ? oldestUnseenID ?? card.id : card.id
        if action != .more { store.markSeen(id: card.id) }
        close()
        return Expansion(cardID: target, reply: action == .reply && card.kind == .question && card.input != nil)
    }
}
