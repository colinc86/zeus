import Foundation
import Observation
import ZeusProtocol
import ZeusDesign

/// An outgoing bubble's UI outcome. A recorded card answer is routed by the runtime, not the model.
enum ConversationOutcome: Equatable, Sendable {
    case sending
    case unconfirmed
    case discarded
    case recordedReply
    case delivery(MessageSendResult)
}

/// Thread identities derive from source card IDs so progress updates and reloads don't replace bubbles.
struct ConversationEntry: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case agentCard(Card)
        case userMessage(Card)
        case userAnswer(cardID: String, response: CardResponse)
    }
    let id: String
    let timestamp: Date
    let content: Content
    var outcome: ConversationOutcome?

    var isUser: Bool {
        switch content { case .agentCard: false; case .userMessage, .userAnswer: true }
    }
    var isMuted: Bool {
        if case .agentCard(let card) = content { return card.status == .dismissed || card.status == .expired }
        return false
    }
    var sourceCardID: String {
        switch content {
        case .agentCard(let card), .userMessage(let card): card.id
        case .userAnswer(let id, _): id
        }
    }
    var body: String {
        switch content {
        case .agentCard(let card), .userMessage(let card): card.body
        case .userAnswer(_, let response): response.summary
        }
    }
}

enum ConversationSendResult: Equatable, Sendable {
    case answered(cardID: String)
    case message(cardID: String, outcome: MessageSendResult)
    case rejected(reason: String)
}

/// UI-independent CONTRACT §10 conversation state. All agent routing remains behind the existing seams.
@MainActor
@Observable
final class ConversationModel {
    var draft = ""
    private(set) var isSending = false
    private(set) var result: ConversationSendResult?
    private var clearedReplyCardIDs: Set<String> = []
    private var explicitReplyCardID: String?
    private var questionsAtReplySelection: Set<String> = []
    private var reveals: [String: TypewriterModel] = [:]
    private var sendingIDs: Set<String> = []
    @ObservationIgnored private let cards: CardStore
    @ObservationIgnored private let messaging: any AgentMessaging
    @ObservationIgnored private let clock: () -> Date

    init(cards: CardStore, messaging: any AgentMessaging, clock: @escaping () -> Date = Date.init) {
        self.cards = cards
        self.messaging = messaging
        self.clock = clock
        cards.observeOutgoingDeliveries(from: messaging)
    }

    /// All cards stay in the conversation, including answered, dismissed and expired agent cards.
    /// At equal timestamps source cards precede answer echoes, with stable arrival order within each.
    @ObservationIgnored private var cachedThread: [ConversationEntry] = []
    @ObservationIgnored private var cachedRevision: UInt64?
    @ObservationIgnored private var cachedSending: Set<String> = []
    @ObservationIgnored private(set) var threadBuildCount = 0

    var thread: [ConversationEntry] {
        let revision = cards.threadRevision
        guard cachedRevision != revision || cachedSending != sendingIDs else { return cachedThread }
        cachedRevision = revision
        cachedSending = sendingIDs
        threadBuildCount += 1
        var entries: [(entry: ConversationEntry, sourceIndex: Int, isAnswer: Bool)] = []
        for (index, card) in cards.cards.enumerated() {
            let id = Self.cardEntryID(card.id)
            entries.append((ConversationEntry(id: id, timestamp: card.createdAt,
                                               content: card.kind == .userMessage ? .userMessage(card) : .agentCard(card),
                                               outcome: sendingIDs.contains(card.id) ? .sending : cards.outgoingStates[card.id]?.presentation), index, false))
            if card.kind != .userMessage, let response = card.response {
                entries.append((ConversationEntry(id: Self.answerEntryID(card.id), timestamp: response.respondedAt,
                                                   content: .userAnswer(cardID: card.id, response: response),
                                                   outcome: .recordedReply), index, true))
            }
        }
        cachedThread = entries.sorted {
            if $0.entry.timestamp != $1.entry.timestamp { return $0.entry.timestamp < $1.entry.timestamp }
            if $0.isAnswer != $1.isAnswer { return !$0.isAnswer }
            return $0.sourceIndex < $1.sourceIndex
        }.map(\.entry)
        return cachedThread
    }

    var unseenCount: Int { cards.unseenCount }
    var isPanelOpen: Bool { cards.isConversationOpen }
    var canSend: Bool { !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Priority never changes conversational chronology or which question the keyboard targets.
    var newestOpenQuestion: Card? {
        cards.cards.enumerated().filter { $0.element.kind == .question && $0.element.status == .open }.max {
            if $0.element.createdAt != $1.element.createdAt { return $0.element.createdAt < $1.element.createdAt }
            return $0.offset < $1.offset
        }?.element
    }

    /// The newest open text-accepting question wins, even when newer options-only questions exist.
    private var newestTextQuestion: Card? {
        cards.cards.enumerated().filter { $0.element.kind == .question && $0.element.status == .open && $0.element.input != nil }.max {
            if $0.element.createdAt != $1.element.createdAt { return $0.element.createdAt < $1.element.createdAt }
            return $0.offset < $1.offset
        }?.element
    }
    var replyTarget: Card? {
        let newest = newestTextQuestion
        if let id = explicitReplyCardID, let newest, questionsAtReplySelection.contains(newest.id),
           let selected = cards.card(id: id), selected.kind == .question, selected.status == .open, selected.input != nil {
            return selected
        }
        guard let newest, !clearedReplyCardIDs.contains(newest.id) else { return nil }
        return newest
    }

    /// Explicit Reply can select any open text question; a newly arriving question still wins by default.
    func rearmReplyTarget(cardID: String) {
        guard let card = cards.card(id: cardID), card.kind == .question, card.status == .open, card.input != nil else { return }
        explicitReplyCardID = cardID
        questionsAtReplySelection = Set(cards.cards.filter { $0.kind == .question && $0.status == .open && $0.input != nil }.map(\.id))
        clearedReplyCardIDs.remove(cardID)
    }

    func openPanel(viewportManaged: Bool = false) {
        if !cards.isConversationOpen {
            finishReveals()
            cards.markAllRevealed()
        }
        cards.expire()
        cards.setConversationOpen(true, automaticallyMarkSeen: !viewportManaged)
    }
    func closePanel() { finishReveals(); cards.setConversationOpen(false) }

    /// Only a newly arriving, visible message can create an animation. The model owns its lifetime.
    func noteArrival(_ card: Card, visible: Bool, animate: Bool) {
        let firstReveal = cards.markRevealed(id: card.id)
        guard firstReveal, card.kind == .message, visible, animate else { return }
        let markdown = ZeusMarkdown.attributed(card.body, choice: .pixel, palette: .dark)
        let reveal = TypewriterModel(clock: clock)
        reveal.configure(text: String(markdown.characters), animate: true)
        reveals[card.id] = reveal
    }
    func revealer(cardID: String) -> TypewriterModel? { reveals[cardID] }
    private func finishReveals() { for reveal in reveals.values { reveal.finish() } }

    /// An explicit Talk action starts a message, without changing or answering historical questions.
    /// Questions arriving afterward can still offer their normal reply chip.
    func beginPlainMessage() {
        explicitReplyCardID = nil
        questionsAtReplySelection.removeAll()
        clearedReplyCardIDs.formUnion(cards.cards.filter {
            $0.kind == .question && $0.status == .open && $0.input != nil
        }.map(\.id))
    }

    /// × / ⌘K opt the current question out; a newly arriving question may still offer its own chip.
    func clearReplyTarget() { beginPlainMessage() }
    /// The UI calls this for Backspace; a nonempty draft must keep normal editing behavior.
    @discardableResult func backspaceInComposer() -> Bool {
        guard draft.isEmpty, replyTarget != nil else { return false }
        clearReplyTarget()
        return true
    }

    /// Any still-open card can be answered, independent of newer messages and composer opt-out.
    @discardableResult func pickOption(cardID: String, optionID: String) -> Bool {
        guard let card = cards.card(id: cardID), card.status == .open, card.kind != .userMessage,
              let option = card.options.first(where: { $0.id == optionID }) else { return false }
        return cards.respond(id: card.id, response: CardResponse(optionID: option.id, optionLabel: option.label,
                                                                respondedAt: clock(), device: .mac))
    }
    /// The newest actionable question/content bubble gets the numbered shortcuts.
    var shortcutTarget: Card? {
        cards.cards.enumerated().filter {
            ($0.element.kind == .question || $0.element.kind == .content) && $0.element.status == .open && !$0.element.options.isEmpty
        }.max {
            if $0.element.createdAt != $1.element.createdAt { return $0.element.createdAt < $1.element.createdAt }
            return $0.offset < $1.offset
        }?.element
    }

    /// ⌘1…⌘9 use the agent's supplied option order.
    @discardableResult func pickNumberedOption(_ number: Int) -> Bool {
        guard (1...9).contains(number), let card = shortcutTarget, card.options.indices.contains(number - 1) else { return false }
        return pickOption(cardID: card.id, optionID: card.options[number - 1].id)
    }

    @discardableResult func send() async -> ConversationSendResult? { await send(draft) }

    /// Captures routing before an async send. A newly arriving question cannot consume an older send.
    @discardableResult func send(_ text: String) async -> ConversationSendResult? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !text.isEmpty else { return nil }
        isSending = true
        result = nil
        defer { isSending = false }
        if let target = replyTarget {
            let accepted = cards.respond(id: target.id, response: CardResponse(text: text, respondedAt: clock(), device: .mac))
            if accepted {
                result = .answered(cardID: target.id)
                clearMatchingDraft(text)
            } else {
                result = .rejected(reason: cards.persistenceError.map { "Could not save your reply. \($0) Try again." }
                    ?? "This question is no longer open. Review the reply target and try again.")
            }
        } else {
            let now = clock()
            let card = Card(kind: .userMessage, body: text, createdAt: now, updatedAt: now, status: .answered)
            let deliveryID = UserMessageDelivery.makeID()
            guard cards.addOutgoing(card, deliveryID: deliveryID) else {
                result = .rejected(reason: "Could not save your message. \(cards.persistenceError ?? "Try again.")")
                return result
            }
            sendingIDs.insert(card.id)
            let outcome = await messaging.sendUserMessage(text, deliveryID: deliveryID)
            _ = cards.setOutgoingState(.init(outcome), cardID: card.id)
            _ = cards.reconcileOutgoingDeliveries(messaging.userMessageDeliveries)
            sendingIDs.remove(card.id)
            result = .message(cardID: card.id, outcome: outcome)
            if case .failed = outcome {} else { clearMatchingDraft(text) }
        }
        return result
    }

    /// Retry the same outgoing bubble, never consuming a newly arrived question or duplicating history.
    func retry(entryID: String) async {
        guard !isSending, let entry = thread.first(where: { $0.id == entryID }),
              case .userMessage = entry.content, case .delivery(.failed)? = entry.outcome else { return }
        isSending = true
        defer { isSending = false }
        guard let deliveryID = cards.deliveryIDForRetry(cardID: entry.sourceCardID),
              cards.setOutgoingState(.sending, cardID: entry.sourceCardID) else { return }
        sendingIDs.insert(entry.sourceCardID)
        let outcome = await messaging.sendUserMessage(entry.body, deliveryID: deliveryID)
        _ = cards.setOutgoingState(.init(outcome), cardID: entry.sourceCardID)
        _ = cards.reconcileOutgoingDeliveries(messaging.userMessageDeliveries)
        sendingIDs.remove(entry.sourceCardID)
        if case .failed = outcome {} else { clearMatchingDraft(entry.body) }
    }

    func pruneClearedHistory() {
        let ids = Set(cards.cards.map(\.id))
        reveals = reveals.filter { ids.contains($0.key) }
        clearedReplyCardIDs.formIntersection(ids)
        questionsAtReplySelection.formIntersection(ids)
        if let id = explicitReplyCardID, !ids.contains(id) { explicitReplyCardID = nil }
    }

    private func clearMatchingDraft(_ submitted: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submitted { draft = "" }
    }
    private static func cardEntryID(_ id: String) -> String { "card:\(id)" }
    private static func answerEntryID(_ id: String) -> String { "answer:\(id)" }
}

extension OutgoingMessageState {
    var presentation: ConversationOutcome {
        switch self {
        // A stopped process may have delivered this. Never offer an automatic duplicate send.
        case .sending: .unconfirmed
        case .delivered, .acked: .delivery(.delivered)
        case .discarded: .discarded
        case .queued(let reason): .delivery(.queued(reason: reason))
        case .failed(let reason): .delivery(.failed(reason: reason))
        }
    }
}
