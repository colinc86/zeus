import Foundation
import Observation
import ZeusProtocol

/// Main-actor card lifecycle and persistence. Responses enter the runtime only through the seam.
@MainActor
@Observable
final class CardStore: CardStoring {
    /// Changes only when the chronological thread or an outgoing caption can change.
    private(set) var threadRevision: UInt64 = 0
    private(set) var cards: [Card] = [] { didSet { if cards != oldValue { threadRevision &+= 1 } } }
    private(set) var revealedIDs: Set<String> = []
    private(set) var seenIDs: Set<String> = []
    private(set) var outgoingStates: [String: OutgoingMessageState] = [:] { didSet { if outgoingStates != oldValue { threadRevision &+= 1 } } }
    private(set) var outgoingDeliveryIDs: [String: String] = [:]
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
        init(cards: [Card], seenIDs: Set<String>, revealedIDs: Set<String>, outgoingStates: [String: OutgoingMessageState] = [:], outgoingDeliveryIDs: [String: String] = [:]) {
            self.cards = cards; self.seenIDs = seenIDs; self.revealedIDs = revealedIDs
            self.outgoingStates = outgoingStates; self.outgoingDeliveryIDs = outgoingDeliveryIDs
        }
        private enum CodingKeys: String, CodingKey { case version, cards, seenIDs, revealedIDs, outgoingStates, outgoingDeliveryIDs }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            cards = try container.decode([Card].self, forKey: .cards)
            seenIDs = try container.decode(Set<String>.self, forKey: .seenIDs)
            outgoingStates = try container.decodeIfPresent([String: OutgoingMessageState].self, forKey: .outgoingStates) ?? [:]
            outgoingDeliveryIDs = try container.decodeIfPresent([String: String].self, forKey: .outgoingDeliveryIDs) ?? [:]
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
        cards.enumerated().filter { $0.element.status == .open }.sorted { lhs, rhs in
            let a = rank(lhs.element.priority), b = rank(rhs.element.priority)
            if a != b { return a > b }
            return lhs.offset > rhs.offset
        }.map(\.element)
    }

    var history: [Card] {
        cards.filter { $0.status != .open }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Agent messages remain in the thread after dismissal/expiry; outgoing messages never badge.
    var unseenCount: Int { cards.filter { $0.kind != .userMessage && !seenIDs.contains($0.id) }.count }
    var hasUnseenCards: Bool { unseenCount > 0 }

    func setConversationOpen(_ open: Bool, automaticallyMarkSeen: Bool = true) {
        self.automaticallyMarkSeen = automaticallyMarkSeen
        isConversationOpen = open
        if open && automaticallyMarkSeen { markAllSeen() }
    }

    /// Batch persistence avoids one disk write per bubble when the thread opens.
    func markAllSeen() {
        let ids = Set(cards.filter { $0.kind != .userMessage }.map(\.id))
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
        if isConversationOpen && automaticallyMarkSeen && card.kind != .userMessage { next.seenIDs.insert(card.id) }
        guard commit(next) else { return }
        if card.status == .open { onAdd?(card) }
    }

    /// Persist the outgoing bubble and its initial state before allowing any agent delivery.
    @discardableResult func addOutgoing(_ card: Card, deliveryID: String = UserMessageDelivery.makeID()) -> Bool {
        guard card.kind == .userMessage, self.card(id: card.id) == nil, !outgoingDeliveryIDs.values.contains(deliveryID) else { return false }
        var nextStates = outgoingStates
        nextStates[card.id] = .sending
        let nextCards = cards + [card]
        var nextIDs = outgoingDeliveryIDs; nextIDs[card.id] = deliveryID
        guard save(snapshot: Snapshot(cards: nextCards, seenIDs: seenIDs, revealedIDs: revealedIDs,
                                      outgoingStates: nextStates, outgoingDeliveryIDs: nextIDs)) else { return false }
        cards = nextCards
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
                                      outgoingStates: next, outgoingDeliveryIDs: outgoingDeliveryIDs)) else {
            // Failed pre-send .sending writes never authorize a send and need no deferred outcome.
            if state != .sending { pendingOutgoingStates[cardID] = state }
            return false
        }
        outgoingStates = next
        pendingOutgoingStates.removeValue(forKey: cardID)
        if pendingOutgoingStates.isEmpty { persistenceError = nil }
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
                            outgoingStates: outgoingStates.filter { ids.contains($0.key) }, outgoingDeliveryIDs: outgoingDeliveryIDs.filter { ids.contains($0.key) })
        guard save(snapshot: next) else { return false }
        cards = next.cards; seenIDs = next.seenIDs; revealedIDs = next.revealedIDs; outgoingStates = next.outgoingStates; outgoingDeliveryIDs = next.outgoingDeliveryIDs
        onHistoryCleared?()
        return true
    }

    func card(id: String) -> Card? { cards.first { $0.id == id } }

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
        if commit(next), card.status == .open, isPlainMessage(card) { retainHistory(keepingNewest: 500, pendingCardIDs: []) }
    }

    /// Consume the reveal durably before it starts. False means already consumed or unable to save.
    @discardableResult func markRevealed(id: String) -> Bool {
        guard let card = card(id: id), card.kind != .userMessage, !revealedIDs.contains(id) else { return false }
        var next = revealedIDs
        next.insert(id)
        guard save(snapshot: Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: next, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs)) else { return false }
        revealedIDs = next
        return true
    }
    func markAllRevealed() {
        let next = revealedIDs.union(cards.filter { $0.kind != .userMessage }.map(\.id))
        guard next != revealedIDs, save(snapshot: Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: next, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs)) else { return }
        revealedIDs = next
    }

    /// Returns false for stale/duplicate responses; persists the answer before notifying the runtime.
    @discardableResult
    func respond(id: String, response: CardResponse) -> Bool {
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
        guard save(snapshot: Snapshot(cards: nextCards, seenIDs: nextSeenIDs, revealedIDs: revealedIDs, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs)) else { return false }
        cards = nextCards
        seenIDs = nextSeenIDs
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
        Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: revealedIDs, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs)
    }
    @discardableResult private func commit(_ next: Snapshot) -> Bool {
        guard save(snapshot: next) else { return false }
        cards = next.cards; seenIDs = next.seenIDs; revealedIDs = next.revealedIDs; outgoingStates = next.outgoingStates; outgoingDeliveryIDs = next.outgoingDeliveryIDs
        return true
    }

    /// Retry a failed write without changing or discarding the last durable state.
    @discardableResult func retryPersistence() -> Bool {
        var next = snapshot
        for (id, state) in pendingOutgoingStates where next.cards.contains(where: { $0.id == id && $0.kind == .userMessage }) {
            if next.outgoingStates[id]?.isTerminal != true { next.outgoingStates[id] = state }
        }
        _ = applyOutgoingDeliveries(outgoingMessaging?.userMessageDeliveries ?? [], to: &next)
        guard commit(next) else { return false }
        pendingOutgoingStates.removeAll()
        persistenceError = nil
        return true
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
            let data = try encoder.encode(snapshot ?? Snapshot(cards: cards, seenIDs: seenIDs, revealedIDs: revealedIDs, outgoingStates: outgoingStates, outgoingDeliveryIDs: outgoingDeliveryIDs))
            try data.write(to: fileURL, options: .atomic)
            // Another successful transaction can still contain an older send caption.
            // Keep the repair action available until the known outcome is committed.
            if pendingOutgoingStates.isEmpty { persistenceError = nil }
            return true
        } catch { persistenceError = "Zeus couldn't save your conversation history. \(error.localizedDescription)"; return false }
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
                            outgoingDeliveryIDs: outgoingDeliveryIDs.filter { ids.contains($0.key) })
        guard commit(next) else { return }
        onHistoryCleared?() // Also prune transient reveals and labels after successful retention.
    }
}
