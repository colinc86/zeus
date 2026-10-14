import Foundation
import Observation
import ZeusProtocol

/// One compose draft. Guards repeat clicks and records each deliberate send once in history.
@MainActor
@Observable
final class ComposeModel {
    var draft = ""
    private(set) var isSending = false
    private var lastResult: MessageSendResult?
    private var lastCardID: String?
    private(set) var result: MessageSendResult? {
        get {
            guard let id = lastCardID, let state = cards.outgoingStates[id] else { return lastResult }
            switch state {
            case .sending: return lastResult
            case .queued(let reason): return .queued(reason: reason)
            case .failed(let reason): return .failed(reason: reason)
            case .delivered, .acked: return .delivered
            case .discarded: return nil
            }
        }
        set { lastResult = newValue }
    }
    @ObservationIgnored private let cards: CardStore
    @ObservationIgnored private let messaging: any AgentMessaging
    @ObservationIgnored private let clock: () -> Date

    init(cards: CardStore, messaging: any AgentMessaging, clock: @escaping () -> Date = Date.init) {
        self.cards = cards
        self.messaging = messaging
        self.clock = clock
        cards.observeOutgoingDeliveries(from: messaging)
    }

    var canSend: Bool { !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        lastCardID = nil
        result = nil
        defer { isSending = false }
        let now = clock()
        let card = Card(kind: .userMessage, body: text, createdAt: now, updatedAt: now, status: .answered)
        let deliveryID = UserMessageDelivery.makeID()
        guard cards.addOutgoing(card, deliveryID: deliveryID) else {
            result = .failed(reason: "Could not save your message. \(cards.persistenceError ?? "Try again.")")
            return
        }
        lastCardID = card.id
        let outcome = await messaging.sendUserMessage(text, deliveryID: deliveryID)
        _ = cards.setOutgoingState(.init(outcome), cardID: card.id)
        _ = cards.reconcileOutgoingDeliveries(messaging.userMessageDeliveries)
        result = outcome
        switch outcome {
        case .delivered, .queued: if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        case .failed: break
        }
    }
}
