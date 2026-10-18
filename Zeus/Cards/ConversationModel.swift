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
        /// A quiet app-owned line, e.g. "Sent your daily summary · View" (L1).
        case notice(ThreadNotice)
        case appChange(ThreadNotice)
        /// A finished day's delivery lines folded into one (FX19): "Zeus sent your assistant 3 things · Show".
        case deliveryGroup(ConversationDeliveryGroup)
    }
    let id: String
    let timestamp: Date
    let content: Content
    var outcome: ConversationOutcome?

    var isUser: Bool {
        switch content { case .agentCard, .notice, .appChange, .deliveryGroup: false; case .userMessage, .userAnswer: true }
    }
    var isNotice: Bool { switch content { case .notice, .appChange, .deliveryGroup: true; default: false } }
    var deliveryGroup: ConversationDeliveryGroup? { if case .deliveryGroup(let group) = content { return group }; return nil }
    var threadNotice: ThreadNotice? { switch content { case .notice(let notice), .appChange(let notice): notice; default: nil } }
    var isRatingHeld: Bool { if case .agentCard(let card) = content { return card.isRatingHeld }; return false }
    var isMuted: Bool {
        if case .agentCard(let card) = content { return card.status == .dismissed || card.status == .expired }
        return false
    }
    var sourceCardID: String {
        switch content {
        case .agentCard(let card), .userMessage(let card): card.id
        case .userAnswer(let id, _): id
        case .notice(let notice), .appChange(let notice): notice.id
        case .deliveryGroup(let group): group.id
        }
    }
    var body: String {
        switch content {
        case .agentCard(let card), .userMessage(let card): card.body
        case .userAnswer(_, let response): response.summary
        case .notice(let notice), .appChange(let notice): notice.summary
        case .deliveryGroup(let group): group.summary
        }
    }
}

/// One finished local day's "Sent …" lines, shown as one line until the user asks (PRIVACY.md §6.1, FX19).
struct ConversationDeliveryGroup: Equatable, Sendable {
    let id: String
    let day: Date
    /// The folded lines, oldest first; each keeps its own View.
    let lines: [ThreadNotice]
    var summary: String { Self.summary(count: lines.count) }
    static func summary(count: Int) -> String { "Zeus sent your assistant \(count) things" }
    /// A delivery line that is finished: received by the assistant. Ready, held, hold, replaced and not-sent lines stay live.
    static func isFinishedDeliveryLine(_ notice: ThreadNotice) -> Bool {
        notice.kind == .learning && notice.summary.hasPrefix("Sent ") && notice.resolvedTitle == nil && notice.secondaryTitle == nil
    }
    /// Folds finished lines from days before `now`'s day, two or more per day; today's lines stay separate.
    static func fold(_ notices: [ThreadNotice], now: Date, calendar: Calendar) -> (groups: [ConversationDeliveryGroup], foldedIDs: Set<String>) {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [ThreadNotice]] = [:]
        for notice in notices where isFinishedDeliveryLine(notice) && notice.createdAt < today {
            byDay[calendar.startOfDay(for: notice.createdAt), default: []].append(notice)
        }
        var groups: [ConversationDeliveryGroup] = []
        for (day, lines) in byDay where lines.count >= 2 {
            let ordered = lines.sorted { $0.createdAt < $1.createdAt }
            let key = String(format: "%04d-%02d-%02d", calendar.component(.year, from: day), calendar.component(.month, from: day), calendar.component(.day, from: day))
            groups.append(.init(id: "delivery-group:" + key, day: day, lines: ordered))
        }
        groups.sort { $0.day < $1.day }
        return (groups, Set(groups.flatMap { $0.lines.map(\.id) }))
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
    var draftAttachments: [Attachment] = []
    var contextCaption: String?
    private(set) var contextItems: [String: ContextDraftItem] = [:]
    var attachmentError: String?
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
    @ObservationIgnored private var cachedDay: Date?
    @ObservationIgnored private var cachedRevision: UInt64?
    @ObservationIgnored private var cachedSending: Set<String> = []
    @ObservationIgnored private(set) var threadBuildCount = 0

    var thread: [ConversationEntry] {
        let revision = cards.threadRevision
        let today = Calendar.current.startOfDay(for: clock())
        guard cachedRevision != revision || cachedSending != sendingIDs || cachedDay != today else { return cachedThread }
        cachedRevision = revision
        cachedSending = sendingIDs
        cachedDay = today
        threadBuildCount += 1
        var entries: [(entry: ConversationEntry, sourceIndex: Int, isAnswer: Bool)] = []
        for (index, card) in cards.cards.enumerated() {
            let id = Self.cardEntryID(card.id)
            entries.append((ConversationEntry(id: id, timestamp: card.createdAt,
                                               content: card.kind == .userMessage ? .userMessage(card) : .agentCard(card),
                                               outcome: sendingIDs.contains(card.id) ? .sending : cards.outgoingStates[card.id]?.presentation), index, false))
            if card.kind != .userMessage, let response = card.response, !response.skipped {
                entries.append((ConversationEntry(id: Self.answerEntryID(card.id), timestamp: response.respondedAt,
                                                   content: .userAnswer(cardID: card.id, response: response),
                                                   outcome: .recordedReply), index, true))
            }
        }
        // A finished day's "Sent …" lines fold into one line (FX19); live lines stay on their own.
        let folded = ConversationDeliveryGroup.fold(cards.notices, now: clock(), calendar: .current)
        for (index, notice) in cards.notices.enumerated() {
            // Update housekeeping never competes with an open question.
            if notice.kind == .agentUpdate && cards.hasOpenQuestion { continue }
            if folded.foldedIDs.contains(notice.id) { continue }
            entries.append((ConversationEntry(id: "notice:\(notice.id)", timestamp: notice.createdAt,
                                             content: notice.kind == .appChange ? .appChange(notice) : .notice(notice)),
                            cards.cards.count + index, false))
        }
        for group in folded.groups {
            let first = cards.notices.firstIndex { $0.id == group.lines[0].id } ?? 0
            entries.append((ConversationEntry(id: "notice:" + group.id, timestamp: group.lines[0].createdAt, content: .deliveryGroup(group)),
                            cards.cards.count + first, false))
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
    var canSend: Bool { !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty) }

    /// Priority never changes conversational chronology or which question the keyboard targets.
    var newestOpenQuestion: Card? {
        cards.cards.enumerated().filter { $0.element.kind == .question && !$0.element.isRatingHeld && $0.element.status == .open }.max {
            if $0.element.createdAt != $1.element.createdAt { return $0.element.createdAt < $1.element.createdAt }
            return $0.offset < $1.offset
        }?.element
    }

    /// The newest open text-accepting question wins, even when newer options-only questions exist.
    private var newestTextQuestion: Card? {
        cards.cards.enumerated().filter { $0.element.kind == .question && !$0.element.isRatingHeld && $0.element.status == .open && $0.element.input != nil }.max {
            if $0.element.createdAt != $1.element.createdAt { return $0.element.createdAt < $1.element.createdAt }
            return $0.offset < $1.offset
        }?.element
    }
    /// Composer text is a single reply (CONTRACT §10): to the newest open text question, or, when none is open, to the newest
    /// options-only question, so a typed "yes, do it" closes the question instead of leaving a "?" over Zeus forever.
    var replyTarget: Card? {
        let newest = newestTextQuestion ?? newestOpenQuestion
        if let id = explicitReplyCardID, newest.map({ questionsAtReplySelection.contains($0.id) }) ?? true,
           let selected = cards.card(id: id), StatusStripState.isSkippable(selected) {
            return selected
        }
        guard let newest, !clearedReplyCardIDs.contains(newest.id) else { return nil }
        return newest
    }

    /// An explicit question jump can select any open ordinary question; new questions still win by default.
    func rearmReplyTarget(cardID: String) {
        guard let card = cards.card(id: cardID), StatusStripState.isSkippable(card) else { return }
        explicitReplyCardID = cardID
        questionsAtReplySelection = Set(cards.cards.filter { $0.kind == .question && $0.status == .open }.map(\.id))
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
            $0.kind == .question && $0.status == .open
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
        let submittedDraft = MessageText.submitted(text)
        let attachments = draftAttachments
        let text = Self.message(text, attaching: attachments)
        guard !isSending, !text.isEmpty else { return nil }
        isSending = true
        result = nil
        defer { isSending = false }
        if let target = replyTarget {
            let accepted = cards.respond(id: target.id, response: CardResponse(text: text, respondedAt: clock(), device: .mac), context: ContextSendIntent(cardID: target.id, body: text, items: attachments.compactMap { contextItems[$0.id] }))
            if accepted {
                result = .answered(cardID: target.id)
                clearMatchingDraft(submittedDraft, attachments: attachments)
                cards.closeOpenHandovers()
            } else {
                result = .rejected(reason: cards.persistenceError.map { "Could not save your reply. \($0) Try again." }
                    ?? "This question is no longer open. Review the reply target and try again.")
            }
        } else {
            let now = clock()
            let card = Card(kind: .userMessage, body: text, attachments: attachments, createdAt: now, updatedAt: now, status: .answered)
            let deliveryID = UserMessageDelivery.makeID()
            guard cards.addOutgoing(card, deliveryID: deliveryID, context: ContextSendIntent(cardID: card.id, body: text, items: attachments.compactMap { contextItems[$0.id] })) else {
                result = .rejected(reason: "Could not save your message. \(cards.persistenceError ?? "Try again.")")
                return result
            }
            sendingIDs.insert(card.id)
            cards.closeOpenHandovers()
            let outcome = await messaging.sendUserMessage(text, deliveryID: deliveryID)
            _ = cards.setOutgoingState(.init(outcome), cardID: card.id)
            _ = cards.reconcileOutgoingDeliveries(messaging.userMessageDeliveries)
            sendingIDs.remove(card.id)
            result = .message(cardID: card.id, outcome: outcome)
            if case .failed = outcome {} else { clearMatchingDraft(submittedDraft, attachments: attachments) }
        }
        return result
    }

    /// Retry the same outgoing bubble, never consuming a newly arrived question or duplicating history.
    func retry(entryID: String) async {
        guard !isSending, let entry = thread.first(where: { $0.id == entryID }),
              case .userMessage(let sentCard) = entry.content, case .delivery(.failed)? = entry.outcome else { return }
        isSending = true
        defer { isSending = false }
        guard let deliveryID = cards.deliveryIDForRetry(cardID: entry.sourceCardID),
              cards.setOutgoingState(.sending, cardID: entry.sourceCardID) else { return }
        sendingIDs.insert(entry.sourceCardID)
        let outcome = await messaging.sendUserMessage(entry.body, deliveryID: deliveryID)
        _ = cards.setOutgoingState(.init(outcome), cardID: entry.sourceCardID)
        _ = cards.reconcileOutgoingDeliveries(messaging.userMessageDeliveries)
        sendingIDs.remove(entry.sourceCardID)
        if case .failed = outcome {} else {
            if Self.message(draft, attaching: draftAttachments) == entry.body {
                clearMatchingDraft(MessageText.submitted(draft), attachments: sentCard.attachments)
            }
        }
    }

    func pruneClearedHistory() {
        let ids = Set(cards.cards.map(\.id))
        reveals = reveals.filter { ids.contains($0.key) }
        clearedReplyCardIDs.formIntersection(ids)
        questionsAtReplySelection.formIntersection(ids)
        if let id = explicitReplyCardID, !ids.contains(id) { explicitReplyCardID = nil }
    }

    private func clearMatchingDraft(_ submitted: String, attachments: [Attachment] = []) {
        if MessageText.submitted(draft) == submitted { draft = "" }
        let sent = Set(attachments.map(\.id))
        draftAttachments.removeAll { sent.contains($0.id) }
        contextItems = contextItems.filter { !sent.contains($0.key) }
        if contextItems.isEmpty { contextCaption = nil }
    }

    func attach(_ items: [Attachment]) {
        var existing = Set(draftAttachments.map(\.target))
        for item in items where draftAttachments.count < AvatarDrop.maximumItems {
            if existing.insert(item.target).inserted { draftAttachments.append(item) }
        }
    }
    func attachContext(_ result: ContextDraftResult) {
        attach(result.items.map(\.attachment))
        let ids = Set(draftAttachments.map(\.id))
        for item in result.items where ids.contains(item.id) { contextItems[item.id] = item }
        contextCaption = result.caption
    }
    func removeAttachment(id: String) {
        guard !isSending else { return }
        draftAttachments.removeAll { $0.id == id }
        if let item = contextItems.removeValue(forKey: id), item.attachment.kind == .file { try? FileManager.default.removeItem(atPath: item.attachment.target) }
        if contextItems.isEmpty { contextCaption = nil }
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
