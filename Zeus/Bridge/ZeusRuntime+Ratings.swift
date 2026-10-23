import Foundation
import ZeusProtocol

extension ZeusRuntime: MessageRatingsProviding {
    var ratings: [MessageRating] { _ = messageRatings?.revision; return messageRatings?.state.ratings ?? [] }
    var mutedDecisions: [String: CardMuteDecision] { _ = messageRatings?.revision; return messageRatings?.state.decisions ?? [:] }
    var mutedToday: [String] { mutedDecisions.filter { $0.value.releasedAt == nil && learningCalendar.isDate($0.value.decidedAt, inSameDayAs: clock.now) }.sorted { $0.value.decidedAt < $1.value.decidedAt }.map(\.key) }
    var ratingSuggestions: [RatingSuggestion] {
        _ = messageRatings?.revision
        return messageRatings?.state.suggestions.filter { suggestion in messageRatings?.state.dismissedSuggestions.contains(suggestion.id) != true && !ratings.contains(where: { $0.scope == .kind && $0.kindKey == suggestion.id }) } ?? []
    }
    var ratingsRevision: UInt64 { messageRatings?.revision ?? 0 }
    var ratingsError: String? { ratingError ?? messageRatings?.lastError }
    func showMuted() { onShowMuted?(mutedToday) }

    func rate(cardID: String, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo {
        guard let card = cards.card(id: cardID), card.origin == .unprompted else { throw ToolArgumentError("Only unsolicited assistant messages can be rated.") }
        return try await changeRating(id: nil, card: card, rating: rating, scope: scope, label: label)
    }
    func update(id: String, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo {
        guard let previous = ratings.first(where: { $0.id == id }) else { throw ToolArgumentError("That rating no longer exists.") }
        let card = Card(id: previous.exampleCardID, kind: .message, body: previous.exampleText, origin: .unprompted)
        return try await changeRating(id: id, card: card, rating: rating, scope: scope, label: label)
    }
    private func changeRating(id: String?, card: Card, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo {
        guard let store = messageRatings else { throw ToolArgumentError("Message preferences are unavailable.") }
        let clean = try MessageRatingStore.validateLabel(label), version = store.state.version, token = generation
        let redactor = learningRedactor ?? LocalRedactor()
        let safeLabel = try MessageRatingStore.validateLabel(await redactor.redact(clean).value)
        let safeExample = await redactor.redact(String(card.body.prefix(300)))
        guard running, generation == token, store.state.version == version else { throw ToolArgumentError("Message preferences changed. Try again.") }
        let key = MessageRatingStore.kindKey(safeLabel)
        let existing = id.flatMap { wanted in store.state.ratings.first { $0.id == wanted } }
            ?? store.state.ratings.first { $0.kindKey == key && $0.scope == .kind && scope == .kind }
        if let id, scope == .kind, store.state.ratings.contains(where: { $0.id != id && $0.kindKey == key && $0.scope == .kind }) {
            throw ToolArgumentError("That kind already has a rating. Edit that entry instead.")
        }
        let value = MessageRating(id: existing?.id ?? "rating_" + UUID().uuidString, kindLabel: safeLabel, kindKey: key,
            rating: rating, scope: scope, exampleCardID: card.id, exampleText: safeExample.value,
            createdAt: existing?.createdAt ?? clock.now, updatedAt: clock.now)
        var next = store.state; next.ratings.removeAll { $0.id == value.id }; next.ratings.append(value)
        let meaning = rating == .up ? "More like this" : rating == .neutral ? "Need-to-know" : "Stop these"
        let text = "Rating: \(meaning) · kind: \(safeLabel) · scope: \(scope.rawValue) · example: \"\(safeExample.value)\". "
            + (scope == .justThisOne ? "Feedback on this message only; do not create a kind rule." : "Apply this to the kind, including similar messages with different labels. Neutral uses your judgment. Replies to user input are unaffected.")
        return try commitRatingChange(next, text: text, subject: value.id)
    }
    func remove(id: String) async throws -> MessageRatingUndo {
        guard let store = messageRatings, let previous = ratings.first(where: { $0.id == id }) else { throw ToolArgumentError("That rating no longer exists.") }
        var next = store.state; next.ratings.removeAll { $0.id == id }
        return try commitRatingChange(next, text: "Rating removed · kind: \(previous.kindLabel). Remove this preference; do not treat it as a Stop rule.", subject: id)
    }
    private func commitRatingChange(_ value: MessageRatingStore.State, text: String, subject: String = "", previousDecision: CardMuteDecision? = nil) throws -> MessageRatingUndo {
        guard let store = messageRatings else { throw ToolArgumentError("Message preferences are unavailable.") }
        let previous = store.state.ratings
        var next = value; next.version = UUID()
        next.outbox.append(.init(id: "d_rating_" + UUID().uuidString, text: text, createdAt: clock.now))
        let receipt = MessageRatingUndo(id: UUID())
        next.undos = [.init(id: receipt.id, subject: subject, version: next.version, ratings: previous, decision: previousDecision)]
        try store.commit(next)
        ratingError = nil; scheduleRatingDelivery()
        return receipt
    }
    func ratingUndo(for ratingOrCardID: String) -> MessageRatingUndo? {
        guard let store = messageRatings, let undo = store.state.undos.last(where: { $0.subject == ratingOrCardID && $0.version == store.state.version }) else { return nil }
        return .init(id: undo.id)
    }
    func undoRating(_ receipt: MessageRatingUndo) async throws {
        guard let store = messageRatings, let saved = store.state.undos.first(where: { $0.id == receipt.id }), saved.version == store.state.version else { throw ToolArgumentError("A later edit changed these preferences. Undo is no longer available.") }
        var next = store.state; next.ratings = saved.ratings
        if let decision = saved.decision { next.decisions[saved.subject] = decision }
        _ = try commitRatingChange(next, text: "Rating edit undone. Use the current preferences below:\n" + MessageRatingStore.preferences(next.ratings))
        if let decision = saved.decision { _ = cards.update(id: saved.subject) { $0.muteDecision = decision }; try checkCardPersistence() }
    }
    func correctMuted(cardID: String) async throws -> MessageRatingUndo {
        guard let store = messageRatings, var decision = store.state.decisions[cardID], decision.releasedAt == nil else { throw ToolArgumentError("That message is no longer muted.") }
        let previous = decision
        decision.releasedAt = clock.now
        var next = store.state; next.decisions[cardID] = decision
        let receipt = try commitRatingChange(next, text: "Rating match corrected: the held message was not this kind: \(decision.kindLabel). The kind preference is unchanged; do not infer a broader approval.", subject: cardID, previousDecision: previous)
        _ = cards.update(id: cardID) { $0.muteDecision = decision }
        try checkCardPersistence()
        return receipt
    }
    func dismissRatingSuggestion(id: String) throws {
        guard let store = messageRatings else { return }; var next = store.state
        next.dismissedSuggestions.insert(id); try store.commit(next)
    }
    func ratingCardShown(id: String) { recordRatingSignal(id: id, edge: "shown") }
    func ratingCardOpened(id: String) { recordRatingSignal(id: id, edge: "opened") }
    func ratingCardDismissed(id: String) { recordRatingSignal(id: id, edge: "dismissed") }
    private func recordRatingSignal(id: String, edge: String) {
        messageRatings?.signal(id: id, edge: edge, at: clock.now); messageRatings?.refreshSuggestions(at: clock.now)
    }

    func prepareRatedCard(_ original: Card, about: String?) async throws -> Card {
        var card = original
        card.about = try about.map(MessageRatingStore.validateLabel)
        guard let store = messageRatings else { return card }
        guard store.isReady || card.origin == .reply else { throw ToolArgumentError("Message preferences are locked. Retry this message after the Mac unlocks.") }
        if !store.isReady { return card }
        let token = generation
        // A concurrent preference edit invalidates the semantic decision; never publish a stale hold.
        for _ in 0..<3 {
            let version = store.state.version
            var decision: CardMuteDecision?
            if card.origin == .unprompted {
                let key = card.about.map(MessageRatingStore.kindKey)
                let kinds = ratings.filter { $0.scope == .kind }
                if let exact = kinds.first(where: { $0.kindKey == key }) {
                    if exact.rating == .down { decision = .init(ratingID: exact.id, kindLabel: exact.kindLabel, reason: "kind: " + exact.kindLabel, engine: "exact", score: 1, threshold: 1, decidedAt: clock.now) }
                } else {
                    for rating in kinds where rating.rating == .down {
                        let input = (card.about ?? "") + "\n" + String(card.body.prefix(300))
                        if let match = await ratingSimilarity.compare(input, with: rating.kindLabel + "\n" + rating.exampleText), match.score >= match.threshold {
                            decision = .init(ratingID: rating.id, kindLabel: rating.kindLabel, reason: "looks like " + rating.kindLabel, engine: match.engine, score: match.score, threshold: match.threshold, decidedAt: clock.now)
                            break
                        }
                    }
                }
            }
            guard running, token == generation else { throw CancellationError() }
            if version != store.state.version { continue }
            card.muteDecision = decision
            if let decision { store.recordDecision(decision, cardID: card.id) }
            if card.origin == .unprompted, decision == nil, let about = card.about {
                var safe = card; safe.about = await (learningRedactor ?? LocalRedactor()).redact(about).value
                guard running, token == generation else { throw CancellationError() }
                if version != store.state.version { continue }
                store.observeCard(safe)
                scheduleRatingSuggestions()
            }
            return card
        }
        throw ToolArgumentError("Message preferences changed while this card was prepared. Try again.")
    }

    func scheduleRatingDelivery() {
        guard running, ratingDeliveryTask == nil, let store = messageRatings, store.isReady else { return }
        guard ratingExportVersion != store.state.version || !store.state.outbox.isEmpty else { return }
        let token = generation, startingVersion = store.state.version
        ratingDeliveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.ratingDeliveryTask = nil
                if self.running, self.generation == token, store.state.version != startingVersion { self.scheduleRatingDelivery() }
            }
            do {
                store.refreshSuggestions(at: self.clock.now)
                let version = store.state.version
                let paths = await (self.learningFolder as? any RatingFolderRecording)?.recordRatings(store.state.ratings) ?? []
                guard self.running, self.generation == token, version == store.state.version else { return }
                self.ratingExportVersion = version
                for event in store.state.outbox {
                    guard self.ledger?.record(id: event.id) == nil else { continue }
                    let target = self.assistantTarget
                    let text = Self.withLearningFiles(event.text, paths: paths)
                    let delivery = Delivery(id: event.id, kind: .learning, sessionKey: target ?? "", content: text,
                        meta: ["kind": "learning", "learning_kind": "rating", "delivery_id": event.id], createdAt: event.createdAt)
                    try self.ledger?.insert(.init(delivery: delivery, awaitingAssistant: target == nil ? true : nil))
                }
                var drained = store.state
                drained.outbox.removeAll { self.ledger?.record(id: $0.id) != nil }
                if drained.outbox.count != store.state.outbox.count { try store.commit(drained) }
                self.ratingError = nil
                self.ratingRetryTask?.cancel(); self.ratingRetryTask = nil
                self.processDueDeliveries()
            } catch {
                self.ratingError = "Zeus couldn't queue the rating for your assistant. It is saved and will be retried."
                self.scheduleRatingRetry()
            }
        }
    }
    private func scheduleRatingRetry() {
        guard running, ratingRetryTask == nil else { return }
        let clock = self.clock, deadline = clock.now.addingTimeInterval(3), token = generation
        ratingRetryTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled, self.running, self.generation == token else { return }
            self.ratingRetryTask = nil
            self.scheduleRatingDelivery()
        }
    }
    func clearMessageRatings() {
        ratingDeliveryTask?.cancel(); ratingDeliveryTask = nil
        ratingRetryTask?.cancel(); ratingRetryTask = nil
        ratingSignalTimer?.cancel(); ratingSignalTimer = nil
        let held = mutedDecisions
        // Erasure must not let the store observer enqueue an empty export while clearing.
        let onChange = messageRatings?.onChange
        messageRatings?.onChange = nil
        defer { messageRatings?.onChange = onChange }
        do { try messageRatings?.clear(); ratingError = nil }
        catch { ratingError = error.localizedDescription; return }
        ratingExportVersion = messageRatings?.state.version
        (learningFolder as? any RatingFolderRecording)?.clearRatingPreferences()
        for (id, _) in held { _ = cards.update(id: id) { $0.muteDecision = nil } }
        scheduleRatingDelivery()
    }
    func scheduleRatingSuggestions() {
        ratingSignalTimer?.cancel(); ratingSignalTimer = nil
        messageRatings?.refreshSuggestions(at: clock.now)
        guard let date = messageRatings?.state.signals.values.filter({ $0.opened == nil }).map({ $0.created.addingTimeInterval(86400) }).filter({ $0 > clock.now }).min() else { return }
        ratingSignalTimer = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(until: date) } catch { return }
            guard self.running, !Task.isCancelled else { return }; self.scheduleRatingSuggestions()
        }
    }
}

@MainActor protocol RatingFolderRecording: AnyObject {
    func recordRatings(_ ratings: [MessageRating]) async -> [String]
    func clearRatingPreferences()
}
