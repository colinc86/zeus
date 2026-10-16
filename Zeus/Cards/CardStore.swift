import Foundation
import Observation
import ZeusProtocol

/// Main-actor card lifecycle and persistence. Responses enter the runtime only through the seam.
@MainActor
@Observable
final class CardStore: CardStoring {
    /// Changes only when the chronological thread or an outgoing caption can change.
    private(set) var threadRevision: UInt64 = 0
    private(set) var cards: [Card] = [] {
        didSet {
            if cards != oldValue {
                threadRevision &+= 1
                let ids = Set(cards.map(\.id))
                contextIntents = contextIntents.filter { ids.contains($0.value.cardID) }
                pendingContextReceipts = pendingContextReceipts.filter { contextIntents[$0.key] != nil }
            }
        }
    }
    private(set) var revealedIDs: Set<String> = []
    private(set) var seenIDs: Set<String> = []
    private(set) var outgoingStates: [String: OutgoingMessageState] = [:] { didSet { if outgoingStates != oldValue { threadRevision &+= 1 } } }
    @ObservationIgnored private(set) var contextIntents: [String: ContextSendIntent] = [:]
    @ObservationIgnored private var pendingContextReceipts: [String: LearningContextDeliveryReceipt] = [:]
    @ObservationIgnored var onContextReceipt: ((String, ContextSendIntent) -> Bool)?
    private(set) var outgoingDeliveryIDs: [String: String] = [:]
    /// Quiet app-owned lines in the thread, such as "Sent your daily summary · View" (L1).
    private(set) var notices: [ThreadNotice] = [] { didSet { if notices != oldValue { threadRevision &+= 1 } } }
    private var noticeActionRevision: UInt64 = 0
    @ObservationIgnored private var noticeActions: [String: (run: @MainActor () -> Void, doneTitle: String?)] = [:]
    /// ST1: the second action of an admission line ("Ignore"). Running either action resolves the line.
    @ObservationIgnored private var noticeSecondaryActions: [String: (run: @MainActor () -> Void, doneTitle: String?)] = [:]
    @ObservationIgnored private var pendingAppChanges: [(notice: ThreadNotice, action: @MainActor () -> Void)] = []
    // Definitive app-owned send outcomes survive a failed caption write in this process.
    // They are published only when the complete history transaction can be saved.
    @ObservationIgnored private var pendingOutgoingStates: [String: OutgoingMessageState] = [:]
    @ObservationIgnored private weak var outgoingMessaging: (any AgentMessaging)?
    private(set) var persistenceError: String?
    private(set) var isConversationOpen = false
    private var automaticallyMarkSeen = true
    /// App-local option actions are handled before any answer is saved or delivered.
    @ObservationIgnored var localActionHandler: ((Card, CardResponse) -> Bool)?
    @ObservationIgnored var responseHandler: ((Card, CardResponse) -> Void)?
    @ObservationIgnored var onHistoryCleared: (() -> Void)?
    @ObservationIgnored var pendingHistoryIDs: (() -> Set<String>)?
    @ObservationIgnored var onRatingRead: ((String) -> Void)?
    @ObservationIgnored var onAdd: ((Card) -> Void)?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let clock: () -> Date

    private struct Snapshot: Codable {
        var version = 1
        var cards: [Card]
        var seenIDs: Set<String>
        var revealedIDs: Set<String>
        var outgoingStates: [String: OutgoingMessageState] = [:]
        var outgoingDeliveryIDs: [String: String] = [:]
        /// Quiet app-owned thread lines (L1). Older history has none.
        var notices: [ThreadNotice] = []
        var contextIntents: [String: ContextSendIntent]?
        init(cards: [Card], seenIDs: Set<String>, revealedIDs: Set<String>, outgoingStates: [String: OutgoingMessageState] = [:], outgoingDeliveryIDs: [String: String] = [:],
             notices: [ThreadNotice], contextIntents: [String: ContextSendIntent]? = nil) {
            self.contextIntents = contextIntents
            self.cards = cards; self.seenIDs = seenIDs; self.revealedIDs = revealedIDs
            self.outgoingStates = outgoingStates; self.outgoingDeliveryIDs = outgoingDeliveryIDs; self.notices = notices
        }
        private enum CodingKeys: String, CodingKey { case version, cards, seenIDs, revealedIDs, outgoingStates, outgoingDeliveryIDs, notices, contextIntents }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            cards = try container.decode([Card].self, forKey: .cards)
            seenIDs = try container.decode(Set<String>.self, forKey: .seenIDs)
            outgoingStates = try container.decodeIfPresent([String: OutgoingMessageState].self, forKey: .outgoingStates) ?? [:]
            outgoingDeliveryIDs = try container.decodeIfPresent([String: String].self, forKey: .outgoingDeliveryIDs) ?? [:]
            contextIntents = try container.decodeIfPresent([String: ContextSendIntent].self, forKey: .contextIntents)
            notices = try container.decodeIfPresent([ThreadNotice].self, forKey: .notices) ?? []
            // Legacy history that was already read must never replay after this upgrade.
            revealedIDs = try container.decodeIfPresent(Set<String>.self, forKey: .revealedIDs) ?? seenIDs
        }
    }

    init(fileURL: URL = ZeusPaths.cards, clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.clock = clock
        load()
        expire()
    }

    /// High-priority arrivals interrupt the stack; each group shows its newest arrivals first.
    var openCards: [Card] {
        cards.enumerated().filter { $0.element.status == .open && !$0.element.isRatingHeld }.sorted { lhs, rhs in
            let a = rank(lhs.element.priority), b = rank(rhs.element.priority)
            if a != b { return a > b }
            return lhs.offset > rhs.offset
        }.map(\.element)
    }

    var history: [Card] {
        cards.filter { $0.status != .open }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Agent messages remain in the thread after dismissal/expiry; outgoing messages never badge.
    var unseenCount: Int { cards.filter { $0.kind != .userMessage && !$0.isRatingHeld && !seenIDs.contains($0.id) }.count }
    var hasUnseenCards: Bool { unseenCount > 0 }

    func setConversationOpen(_ open: Bool, automaticallyMarkSeen: Bool = true) {
        self.automaticallyMarkSeen = automaticallyMarkSeen
        isConversationOpen = open
        if open && automaticallyMarkSeen { markAllSeen() }
    }

    /// Batch persistence avoids one disk write per bubble when the thread opens.
    func markAllSeen() {
        let ids = Set(cards.filter { $0.kind != .userMessage && !$0.isRatingHeld }.map(\.id))
        guard !ids.isSubset(of: seenIDs) else { return }
        var next = snapshot
        let newlyEligible = cards.contains { $0.status == .open && isPlainMessage($0) && !seenIDs.contains($0.id) }
        next.seenIDs.formUnion(ids)
        if commit(next), newlyEligible { retainHistory(keepingNewest: 500, pendingCardIDs: []) }
    }
    var hasOpenQuestion: Bool {
        openCards.contains { $0.kind == .question || $0.input != nil || !$0.options.isEmpty }
    }

    func add(_ card: Card) {
        // A repeated tool call must never reopen a card or replay a recorded response.
        guard self.card(id: card.id) == nil else { return }
        var card = card
        if card.status == .open, let expiry = card.expiresAt, expiry <= clock() {
            card.status = .expired
            card.updatedAt = clock()
        }
        var next = snapshot
        next.cards.append(card)
        if isConversationOpen && automaticallyMarkSeen && card.kind != .userMessage && !card.isRatingHeld { next.seenIDs.insert(card.id) }
        guard commit(next) else { return }
        if card.status == .open { onAdd?(card) }
    }

    /// Persist the outgoing bubble and its initial state before allowing any agent delivery.
    @discardableResult func addOutgoing(_ card: Card, deliveryID: String = UserMessageDelivery.makeID(), context: ContextSendIntent? = nil) -> Bool {
        guard card.kind == .userMessage, self.card(id: card.id) == nil, !outgoingDeliveryIDs.values.contains(deliveryID) else { return false }
        var nextContexts = contextIntents
        if let context { nextContexts["delivery:" + deliveryID] = context }
        var nextStates = outgoingStates
        nextStates[card.id] = .sending
        let nextCards = cards + [card]
        var nextIDs = outgoingDeliveryIDs; nextIDs[card.id] = deliveryID
        guard save(snapshot: Snapshot(cards: nextCards, seenIDs: seenIDs, revealedIDs: revealedIDs,
                                      outgoingStates: nextStates, outgoingDeliveryIDs: nextIDs, notices: notices, contextIntents: nextContexts)) else { return false }
        cards = nextCards
        contextIntents = nextContexts
        outgoingStates = nextStates
        outgoingDeliveryIDs = nextIDs
        return true
    }

    /// Store the last known send outcome with the same history snapshot as the bubble.
    @discardableResult func setOutgoingState(_ state: OutgoingMessageState, cardID: String) -> Bool {
        guard card(id: cardID)?.kind == .userMessage else { return false }
        if outgoingStates[cardID]?.isTerminal == true && !state.isTerminal {
            pendingOutgoingStates.removeValue(forKey: cardID); return true
        }
        var next = outgoingStates
        next[cardID] = state
        guard save(snapshot: Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: revealedIDs,
                                      outgoingStates: next, outgoingDeliveryIDs: outgoingDeliveryIDs, notices: notices)) else {
            // Failed pre-send .sending writes never authorize a send and need no deferred outcome.
            if state != .sending { pendingOutgoingStates[cardID] = state }
            return false
        }
        outgoingStates = next
        pendingOutgoingStates.removeValue(forKey: cardID)
        if pendingOutgoingStates.isEmpty && pendingAppChanges.isEmpty { persistenceError = nil }
        return true
    }

    /// Upgrade an explicitly retried legacy failure; unknown legacy sends are never replayed.
    func deliveryIDForRetry(cardID: String) -> String? {
        if let id = outgoingDeliveryIDs[cardID] { return id }
        guard card(id: cardID)?.kind == .userMessage else { return nil }
        var next = snapshot
        let id = UserMessageDelivery.makeID(); next.outgoingDeliveryIDs[cardID] = id
        return commit(next) ? id : nil
    }

    /// One observer follows the hub across runtime installation, reconnect and committed snapshots.
    func observeOutgoingDeliveries(from messaging: any AgentMessaging) {
        guard outgoingMessaging.map({ ObjectIdentifier($0) }) != ObjectIdentifier(messaging) else { return }
        outgoingMessaging = messaging
        reconcileOutgoingDeliveries(messaging.userMessageDeliveries)
        observeOutgoingSnapshot()
    }
    private func observeOutgoingSnapshot() {
        withObservationTracking { _ = outgoingMessaging?.userMessageDeliveries } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileOutgoingDeliveries(self.outgoingMessaging?.userMessageDeliveries ?? [])
                self.observeOutgoingSnapshot()
            }
        }
    }
    @discardableResult func reconcileOutgoingDeliveries(_ deliveries: [UserMessageDelivery]) -> Bool {
        var next = snapshot
        let confirmed = applyOutgoingDeliveries(deliveries, to: &next)
        let needsWrite = next.cards != cards || next.outgoingStates != outgoingStates
        if needsWrite {
            guard commit(next) else { return false }
        }
        // A committed runtime snapshot outranks any older app-owned completion.
        for id in confirmed { pendingOutgoingStates.removeValue(forKey: id) }
        if needsWrite && pendingOutgoingStates.isEmpty { persistenceError = nil }
        return true
    }
    private func applyOutgoingDeliveries(_ deliveries: [UserMessageDelivery], to next: inout Snapshot) -> Set<String> {
        let byID = Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        var confirmed: Set<String> = []
        for index in next.cards.indices {
            let id = next.cards[index].id
            guard let deliveryID = next.outgoingDeliveryIDs[id], let delivery = byID[deliveryID] else { continue }
            confirmed.insert(id)
            let state: OutgoingMessageState = switch delivery.state {
            case .queued: .queued(delivery.reason ?? "Waiting for your assistant.")
            case .delivered: .delivered
            case .acked: .acked
            case .discarded: .discarded
            }
            if next.outgoingStates[id]?.isTerminal != true || state.isTerminal { next.outgoingStates[id] = state }
            if let key = delivery.sessionKey { next.cards[index].sessionKey = key }
        }
        return confirmed
    }

    /// Seen plain messages are history even though their tool-level status remains open.
    /// Questions, actions and attachment-bearing cards still require an explicit resolution.
    private func protectsHistory(_ card: Card) -> Bool {
        guard card.status == .open, card.kind != .userMessage else { return false }
        return !(isPlainMessage(card) && seenIDs.contains(card.id))
    }
    private func isPlainMessage(_ card: Card) -> Bool {
        card.kind == .message && card.options.isEmpty && card.input == nil && card.attachments.isEmpty
    }

    /// Clear read, non-actionable messages and completed history, preserving active work.
    @discardableResult func clearConversation() -> Bool {
        let pending = pendingHistoryIDs?() ?? []
        let kept = cards.filter { protectsHistory($0) || pending.contains($0.id) || outgoingStates[$0.id]?.protectsHistory == true }
        let ids = Set(kept.map(\.id))
        let next = Snapshot(cards: kept, seenIDs: seenIDs.intersection(ids), revealedIDs: revealedIDs.intersection(ids),
                            outgoingStates: outgoingStates.filter { ids.contains($0.key) }, outgoingDeliveryIDs: outgoingDeliveryIDs.filter { ids.contains($0.key) }, notices: [])
        guard save(snapshot: next) else { return false }
        let newlySeen = next.seenIDs.subtracting(seenIDs)
        cards = next.cards; seenIDs = next.seenIDs; revealedIDs = next.revealedIDs; outgoingStates = next.outgoingStates; outgoingDeliveryIDs = next.outgoingDeliveryIDs; notices = next.notices
        pruneNoticeActions()
        pendingAppChanges.removeAll()
        if pendingOutgoingStates.isEmpty && pendingAppChanges.isEmpty { persistenceError = nil }
        onHistoryCleared?()
        return true
    }

    func card(id: String) -> Card? { cards.first { $0.id == id } }

    /// Adds a quiet thread line. It never badges, peeks or plays a sound. The newest 200 are kept.
    /// `action` (e.g. AC2's Undo) lives only in memory: after a relaunch the line shows without its button.
    /// Running it once replaces the button with `doneTitle` ("Undone").
    @discardableResult func recordNotice(_ notice: ThreadNotice, action: (@MainActor () -> Void)? = nil, doneTitle: String? = nil) -> Bool {
        guard !notices.contains(where: { $0.id == notice.id }) else { return false }
        var next = snapshot
        next.notices = Array((next.notices + [notice]).suffix(ThreadNotice.keep))
        guard commit(next) else { return false }
        if let action { noticeActions[notice.id] = (action, doneTitle); noticeActionRevision &+= 1 }
        return true
    }
    /// Reconnects an app-owned action after restoring a durable notice, or disables a stale action.
    func setNoticeAction(id: String, action: (@MainActor () -> Void)?) {
        guard notices.contains(where: { $0.id == id }) else { return }
        let wasAvailable = noticeActions[id] != nil
        if let action { noticeActions[id] = (action, nil) }
        else { noticeActions.removeValue(forKey: id) }
        if wasAvailable != (action != nil) { noticeActionRevision &+= 1 }
    }
    func setSecondaryNoticeAction(id: String, action: (@MainActor () -> Void)?) {
        guard notices.contains(where: { $0.id == id }) else { return }
        let wasAvailable = noticeSecondaryActions[id] != nil
        if let action { noticeSecondaryActions[id] = (action, nil) }
        else { noticeSecondaryActions.removeValue(forKey: id) }
        if wasAvailable != (action != nil) { noticeActionRevision &+= 1 }
    }
    /// Whether the line's in-memory action is still available.
    func hasNoticeAction(id: String) -> Bool {
        _ = noticeActionRevision
        return noticeActions[id] != nil
    }
    /// Marks the line done, then runs its action once. A failed history write keeps the action for a retry, and a
    /// reload never shows it again.
    func performNoticeAction(id: String) {
        guard let (action, doneTitle) = noticeActions[id],
              updateNotice(id: id, { $0.resolvedTitle = doneTitle ?? $0.resolvedTitle }) else { return }
        noticeActions.removeValue(forKey: id); noticeActionRevision &+= 1
        // An admission line resolves as a whole: its other action goes too (ST1).
        if noticeSecondaryActions.removeValue(forKey: id) != nil, doneTitle != nil { _ = updateNotice(id: id) { $0.secondaryTitle = nil } }
        action()
    }
    /// ST1: the second action ("Ignore") of an admission line.
    func hasSecondaryNoticeAction(id: String) -> Bool {
        _ = noticeActionRevision
        return noticeSecondaryActions[id] != nil
    }
    func performSecondaryNoticeAction(id: String) {
        guard let (action, doneTitle) = noticeSecondaryActions[id],
              updateNotice(id: id, { $0.resolvedTitle = doneTitle ?? $0.resolvedTitle; $0.secondaryTitle = nil }) else { return }
        noticeSecondaryActions.removeValue(forKey: id); noticeActions.removeValue(forKey: id); noticeActionRevision &+= 1
        action()
    }
    @discardableResult func updateNotice(id: String, _ mutate: (inout ThreadNotice) -> Void) -> Bool {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return false }
        var next = snapshot
        mutate(&next.notices[index])
        next.notices[index].id = id
        return commit(next)
    }
    /// Removes one transient status notice without clearing unrelated learning history.
    @discardableResult func removeNotice(id: String) -> Bool {
        guard notices.contains(where: { $0.id == id }) else { return true }
        var next = snapshot; next.notices.removeAll { $0.id == id }
        guard commit(next) else { return false }
        pruneNoticeActions(); return true
    }
    /// "Delete everything" in Settings › Privacy also removes the summaries' thread lines.
    @discardableResult func removeNotices(kind: ThreadNotice.Kind) -> Bool {
        guard notices.contains(where: { $0.kind == kind }) else { return true }
        var next = snapshot
        next.notices.removeAll { $0.kind == kind }
        return commit(next)
    }

    @discardableResult
    func update(id: String, _ mutate: (inout Card) -> Void) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return false }
        let original = cards[index]
        var updated = original
        mutate(&updated)
        updated.id = original.id
        // Text/progress updates cannot resurrect a terminal card or erase its response.
        if original.status != .open {
            updated.status = original.status
            updated.response = original.response
        }
        updated.updatedAt = clock()
        var next = snapshot
        next.cards[index] = updated
        next.cards = expired(next.cards)
        return commit(next)
    }

    func dismiss(id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards[index].status != .dismissed,
              cards[index].kind != .userMessage else { return }
        var next = snapshot
        next.cards[index].status = .dismissed
        next.cards[index].updatedAt = clock()
        _ = commit(next)
    }

    func markSeen(id: String) {
        guard let card = card(id: id), card.kind != .userMessage, !seenIDs.contains(id) else { return }
        var next = snapshot
        next.seenIDs.insert(id)
        if commit(next) {
            if card.status == .open, isPlainMessage(card) { retainHistory(keepingNewest: 500, pendingCardIDs: []) }
        }
    }

    /// Consume the reveal durably before it starts. False means already consumed or unable to save.
    @discardableResult func markRevealed(id: String) -> Bool {
        guard let card = card(id: id), card.kind != .userMessage, !revealedIDs.contains(id) else { return false }
        var next = revealedIDs
        next.insert(id)
        guard save(snapshot: Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: next, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs, notices: notices)) else { return false }
        revealedIDs = next
        return true
    }
    func markAllRevealed() {
        let next = revealedIDs.union(cards.filter { $0.kind != .userMessage && !$0.isRatingHeld }.map(\.id))
        guard next != revealedIDs, save(snapshot: Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: next, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs, notices: notices)) else { return }
        revealedIDs = next
    }

    /// Skip is an explicit user response, never a native permission choice or navigation action.
    nonisolated static let managedActionPrefix = "managed-block_"
    nonisolated static func canSkip(_ card: Card) -> Bool {
        card.status == .open && card.kind != .userMessage && !card.id.hasPrefix(managedActionPrefix)
            && (card.kind == .question || card.input != nil || !card.options.isEmpty)
    }
    @discardableResult func skip(id: String) -> Bool {
        guard let card = card(id: id), Self.canSkip(card) else { return false }
        return respond(id: id, response: CardResponse(respondedAt: clock(), device: .mac, skipped: true))
    }

    /// Returns false for stale/duplicate responses; persists the answer before notifying the runtime.
    @discardableResult
    func respond(id: String, response: CardResponse) -> Bool { respond(id: id, response: response, context: nil) }

    @discardableResult func respond(id: String, response: CardResponse, context: ContextSendIntent?) -> Bool {
        expire()
        guard let index = cards.firstIndex(where: { $0.id == id }),
              cards[index].status == .open, cards[index].response == nil,
              cards[index].expiresAt.map({ $0 > clock() }) ?? true else { return false }
        if localActionHandler?(cards[index], response) == true { return true }
        var nextCards = cards
        var nextSeenIDs = seenIDs
        nextCards[index].response = response
        nextCards[index].status = .answered
        nextCards[index].updatedAt = clock()
        nextSeenIDs.insert(id)
        let answered = nextCards[index]
        var nextContexts = contextIntents
        if let context { nextContexts["card:" + id] = context }
        guard commit(Snapshot(cards: nextCards, seenIDs: nextSeenIDs, revealedIDs: revealedIDs, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs, notices: notices, contextIntents: nextContexts)) else { return false }
        responseHandler?(answered, response)
        return true
    }

    func expire(saveChanges: Bool = true) {
        var next = snapshot
        next.cards = expired(next.cards)
        guard next.cards != cards else { return }
        // No caller may publish an unpersisted expiry, including the old saveChanges:false path.
        _ = commit(next)
    }

    private func expired(_ proposed: [Card]) -> [Card] {
        let now = clock()
        return proposed.map { original in
            var card = original
            if card.status == .open, let expiry = card.expiresAt, expiry <= now {
                card.status = .expired; card.updatedAt = now
            }
            return card
        }
    }

    private var snapshot: Snapshot {
        Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: revealedIDs, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs, notices: notices)
    }
    @discardableResult private func commit(_ next: Snapshot) -> Bool {
        guard save(snapshot: next) else { return false }
        let newlySeen = next.seenIDs.subtracting(seenIDs)
        cards = next.cards; seenIDs = next.seenIDs; revealedIDs = next.revealedIDs; outgoingStates = next.outgoingStates; outgoingDeliveryIDs = next.outgoingDeliveryIDs; notices = next.notices
        if let contexts = next.contextIntents { contextIntents = contexts }
        pruneNoticeActions()
        for card in next.cards where newlySeen.contains(card.id) && card.kind != .userMessage { onRatingRead?(card.id) }
        return true
    }

    /// Runtime calls only after a real consumed/write receipt. A queued attempt has no receipt and no ledger row.
    func acceptContextReceipt(_ receipt: LearningContextDeliveryReceipt) {
        let key = receipt.cardID.map { "card:" + $0 } ?? "delivery:" + receipt.deliveryID
        guard contextIntents[key] != nil else { return }
        pendingContextReceipts[key] = receipt
        retryContextReceipts()
    }
    func retryContextReceipts() {
        if !pendingContextReceipts.isEmpty {
            var contexts = contextIntents
            for (key, receipt) in pendingContextReceipts {
                guard var intent = contexts[key] else { continue }
                intent.receipt = .init(receipt); contexts[key] = intent
            }
            var next = snapshot; next.contextIntents = contexts
            guard commit(next) else { return } // Keep the real receipt in RAM until history becomes writable.
            pendingContextReceipts.removeAll()
        }
        for (key, intent) in contextIntents where intent.receipt != nil {
            guard onContextReceipt?(key, intent) == true else { continue }
            var next = snapshot; var contexts = contextIntents; contexts.removeValue(forKey: key); next.contextIntents = contexts
            _ = commit(next)
        }
    }

    /// Retry a failed write without changing or discarding the last durable state.
    @discardableResult func retryPersistence() -> Bool {
        var next = snapshot
        for (id, state) in pendingOutgoingStates where next.cards.contains(where: { $0.id == id && $0.kind == .userMessage }) {
            if next.outgoingStates[id]?.isTerminal != true { next.outgoingStates[id] = state }
        }
        _ = applyOutgoingDeliveries(outgoingMessaging?.userMessageDeliveries ?? [], to: &next)
        next.notices = Array((next.notices + pendingAppChanges.map(\.notice)).suffix(ThreadNotice.keep))
        guard commit(next) else { return false }
        for pending in pendingAppChanges where notices.contains(where: { $0.id == pending.notice.id }) {
            noticeActions[pending.notice.id] = (pending.action, "Undone"); noticeActionRevision &+= 1
        }
        pendingAppChanges.removeAll()
        pendingOutgoingStates.removeAll()
        persistenceError = nil
        retryContextReceipts()
        return pendingContextReceipts.isEmpty
    }

    private func rank(_ priority: Card.Priority) -> Int {
        switch priority { case .low: 0; case .normal: 1; case .high: 2 }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.version == 1 else {
                persistenceError = "Zeus can't read this conversation history (format \(snapshot.version)). It was kept untouched."
                return
            }
            var ids: Set<String> = []
            cards = snapshot.cards.filter { ids.insert($0.id).inserted }
            seenIDs = snapshot.seenIDs.intersection(ids)
            revealedIDs = snapshot.revealedIDs.intersection(ids)
            outgoingStates = snapshot.outgoingStates.filter { ids.contains($0.key) }
            outgoingDeliveryIDs = snapshot.outgoingDeliveryIDs.filter { ids.contains($0.key) }
            notices = snapshot.notices
            contextIntents = (snapshot.contextIntents ?? [:]).filter { ids.contains($0.value.cardID) }
        } catch { persistenceError = "Zeus couldn't read your conversation history. \(error.localizedDescription)" }
    }

    @discardableResult private func save(snapshot: Snapshot? = nil) -> Bool {
        do {
            // Do not overwrite a corrupt/unknown history file after a failed load.
            if persistenceError?.hasPrefix("Zeus couldn't read") == true ||
                persistenceError?.hasPrefix("Zeus can't read this conversation history") == true { return false }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var next = snapshot ?? self.snapshot
            let ids = Set(next.cards.map(\.id))
            next.contextIntents = (next.contextIntents ?? contextIntents).filter { ids.contains($0.value.cardID) }
            let data = try encoder.encode(next)
            try data.write(to: fileURL, options: .atomic)
            // Another successful transaction can still contain an older send caption.
            // Keep the repair action available until the known outcome is committed.
            if pendingOutgoingStates.isEmpty && pendingAppChanges.isEmpty { persistenceError = nil }
            return true
        } catch { persistenceError = "Zeus couldn't save your conversation history. \(error.localizedDescription)"; return false }
    }
}

extension CardStore: AppChangeRecording {
    func recordAppChange(_ change: AppChange) {
        let notice = ThreadNotice(kind: .appChange, createdAt: clock(), summary: change.summary, actionTitle: change.undoTitle)
        if !recordNotice(notice, action: change.undo, doneTitle: "Undone") {
            // The app already changed. Retain its history/Undo for the existing Retry Saving History action.
            pendingAppChanges.append((notice, change.undo))
        }
    }
    private func pruneNoticeActions() {
        let ids = Set(notices.map(\.id))
        let previousCount = noticeActions.count + noticeSecondaryActions.count
        noticeActions = noticeActions.filter { ids.contains($0.key) }
        noticeSecondaryActions = noticeSecondaryActions.filter { ids.contains($0.key) }
        if previousCount != noticeActions.count + noticeSecondaryActions.count { noticeActionRevision &+= 1 }
    }
}

/// App-owned last-known delivery state; runtime acknowledgments require a correlated seam.
enum OutgoingMessageState: Codable, Equatable {
    case sending
    case delivered
    case queued(String)
    case failed(String)
    case acked
    case discarded
    var isTerminal: Bool { self == .acked || self == .discarded }
    var protectsHistory: Bool {
        switch self { case .sending, .delivered, .queued, .failed: true; case .acked, .discarded: false }
    }

    init(_ result: MessageSendResult) {
        switch result {
        case .delivered: self = .delivered
        case .queued(let reason): self = .queued(reason)
        case .failed(let reason): self = .failed(reason)
        }
    }
}

/// Runtime retention uses the same save-before-publish transaction as user actions.
extension CardStore: CardHistoryRetaining {
    func retainHistory(keepingNewest count: Int, pendingCardIDs: Set<String>) {
        // Unconfirmed outgoing bubbles (sending, delivered, queued, unsaved failures) are never pruned.
        let pending = pendingCardIDs.union(pendingHistoryIDs?() ?? [])
            .union(outgoingStates.filter { $0.value.protectsHistory }.map(\.key))
        let newest = Set(cards.enumerated().sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset > $1.offset : $0.element.createdAt > $1.element.createdAt
        }.prefix(max(0, count)).map { $0.element.id })
        let kept = cards.filter {
            newest.contains($0.id) || pending.contains($0.id) || protectsHistory($0)
        }
        guard kept.count != cards.count else { return }
        let ids = Set(kept.map(\.id))
        let next = Snapshot(cards: kept, seenIDs: seenIDs.intersection(ids), revealedIDs: revealedIDs.intersection(ids),
                            outgoingStates: outgoingStates.filter { ids.contains($0.key) },
                            outgoingDeliveryIDs: outgoingDeliveryIDs.filter { ids.contains($0.key) }, notices: notices)
        guard commit(next) else { return }
        onHistoryCleared?() // Also prune transient reveals and labels after successful retention.
    }
}

// MARK: - ST1: who may talk to Zeus

extension CardStore: AdmissionNoticeRecording {
    /// The line is persisted once; its closures live only in memory and are reconnected on later calls.
    @discardableResult func recordAdmissionNotice(_ notice: AdmissionNotice) -> Bool {
        let line = ThreadNotice(id: notice.id, kind: .admission, createdAt: notice.createdAt, summary: notice.summary,
                                actionTitle: notice.primary.title, secondaryTitle: notice.secondary?.title)
        // An action with no done title stays available after it runs ("Change", "Open Settings").
        func reinstalling(_ action: AdmissionNotice.Action, primary: Bool) -> @MainActor () -> Void {
            { [weak self] in
                action.run()
                guard action.doneTitle == nil, let self, self.notices.contains(where: { $0.id == notice.id && $0.resolvedTitle == nil }) else { return }
                if primary { self.noticeActions[notice.id] = (reinstalling(action, primary: true), nil) }
                else { self.noticeSecondaryActions[notice.id] = (reinstalling(action, primary: false), nil) }
                self.noticeActionRevision &+= 1
            }
        }
        if let existing = notices.first(where: { $0.id == notice.id }) {
            guard existing.resolvedTitle == nil else { return false }
            noticeActions[notice.id] = (reinstalling(notice.primary, primary: true), notice.primary.doneTitle)
            if let secondary = notice.secondary { noticeSecondaryActions[notice.id] = (reinstalling(secondary, primary: false), secondary.doneTitle) }
            noticeActionRevision &+= 1
            return false
        }
        guard recordNotice(line, action: reinstalling(notice.primary, primary: true), doneTitle: notice.primary.doneTitle) else { return false }
        if let secondary = notice.secondary {
            noticeSecondaryActions[notice.id] = (reinstalling(secondary, primary: false), secondary.doneTitle); noticeActionRevision &+= 1
        }
        return true
    }
}

extension Card {
    /// UI suppression follows the durable runtime decision, never the agent's priority.
    var isRatingHeld: Bool { origin != .reply && muteDecision != nil && muteDecision?.releasedAt == nil }
}
