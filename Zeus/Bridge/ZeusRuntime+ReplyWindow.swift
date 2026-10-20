import Foundation
import ZeusProtocol

/// Every message the assistant sends while answering the user is a reply (CONTRACT §10).
/// The typing row ends at the first post; the reply window stays open until the answer ends.
extension ZeusRuntime {
    /// One open answer to the user in one session. Never persisted or exposed to agents.
    struct ReplyWindow {
        /// The user message, card answer or answered `ask:` that opened the answer.
        let deliveryID: String
        /// When the answered input reached the session. Evidence older than this belongs to an earlier turn.
        let openedAt: Date
        /// When this session last called a Zeus tool, for the idle cap.
        var lastActivity: Date
        /// The last native Claude turn footer when the window opened (managed pane only).
        let completionAtStart: String?
    }

    /// An external session without turn hooks has no end evidence; a quiet half hour ends its answer.
    static let replyWindowIdleCap: TimeInterval = 30 * 60

    /// A user message, an answer to a card, or a synchronous ask's answer.
    func isReplyDelivery(_ id: String) -> Bool {
        if id.hasPrefix("ask:") { return true }
        guard let kind = ledger?.record(id: id)?.delivery.kind else { return false }
        return kind == .reply || kind == .userMessage
    }

    /// Opens or replaces the window for the user's input; any other delivery that reaches the session ends the answer.
    func noteReplyWindowDelivery(sessionKey: String, deliveryID: String, startedAt: Date?) {
        if isReplyDelivery(deliveryID) { openReplyWindow(sessionKey: sessionKey, deliveryID: deliveryID, startedAt: startedAt) }
        else { closeReplyWindow(sessionKey: sessionKey) }
    }

    func openReplyWindow(sessionKey: String, deliveryID: String, startedAt: Date?) {
        let now = clock.now
        if var window = replyWindows[sessionKey], window.deliveryID == deliveryID {
            window.lastActivity = now
            replyWindows[sessionKey] = window
            return
        }
        replyWindows[sessionKey] = .init(deliveryID: deliveryID, openedAt: min(startedAt ?? now, now), lastActivity: now,
                                         completionAtStart: managedCompletion(sessionKey: sessionKey))
    }

    func closeReplyWindow(sessionKey: String) { replyWindows.removeValue(forKey: sessionKey) }

    /// Tool traffic keeps an answer open; a call after the idle cap first closes it.
    func noteReplyWindowActivity(sessionKey: String) {
        guard var window = replyWindows[sessionKey] else { return }
        guard clock.now.timeIntervalSince(window.lastActivity) < Self.replyWindowIdleCap else { closeReplyWindow(sessionKey: sessionKey); return }
        window.lastActivity = clock.now
        replyWindows[sessionKey] = window
    }

    /// A native turn-ended hook closes the answer it ends. A hook naming another input, or one that
    /// fired before this input arrived, belongs to a different turn.
    func noteReplyWindowTurnEnded(sessionKey: String, deliveryID: String?, firedAt: TimeInterval) {
        guard let window = replyWindows[sessionKey], deliveryID == nil || deliveryID == window.deliveryID,
              window.openedAt.timeIntervalSince1970 <= firedAt else { return }
        closeReplyWindow(sessionKey: sessionKey)
    }

    /// Runtime-classified, never agent-chosen. A status alone never makes a reply.
    func ratingOrigin(sessionKey: String) -> CardOrigin {
        if let record = activityRecords[sessionKey], record.deadline > clock.now, let id = record.deliveryID {
            guard isReplyDelivery(id) else { return .unprompted }
            // Covers inputs whose activity began from an early acknowledgment.
            openReplyWindow(sessionKey: sessionKey, deliveryID: id, startedAt: record.responseBeganAt)
            return .reply
        }
        guard let window = replyWindows[sessionKey] else { return .unprompted }
        guard clock.now.timeIntervalSince(window.lastActivity) < Self.replyWindowIdleCap else {
            closeReplyWindow(sessionKey: sessionKey)
            return .unprompted
        }
        return .reply
    }
}
