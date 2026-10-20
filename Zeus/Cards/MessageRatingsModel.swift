import Foundation
import Observation
import ZeusProtocol

/// App presentation only. The runtime owns classification, persistence, matching and guarded Undo.
@MainActor @Observable
final class MessageRatingsModel {
    struct Draft: Equatable {
        var label: String
        var scope = MessageRatingScope.kind
        var editingLabel = false
        var originalLabel: String?
    }
    struct Confirmation {
        let text: String
        let receipt: MessageRatingUndo?
    }
    private(set) var drafts: [String: Draft] = [:]
    private(set) var confirmations: [String: Confirmation] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var expandedMuted: Set<String> = []
    var selectedRatingID: String?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var dailyTask: Task<Void, Never>?
    isolated deinit { dailyTask?.cancel() }
    func start() { guard !observing else { return }; observing = true; generation += 1; reconcile(); observe() }
    func stop() { observing = false; generation += 1; dailyTask?.cancel(); dailyTask = nil; provider?.onShowMuted = nil }
    private func observe() {
        guard observing else { return }
        let current = generation
        withObservationTracking { _ = provider?.ratingsRevision; _ = cards.cards; _ = provider?.mutedToday; _ = dailyHour() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.generation == current else { return }
                self.reconcile(); self.observe()
            }
        }
    }
    /// One quiet summary at the end of each local day; a late launch also restores older summaries.
    func reconcile(now: Date = Date(), calendar: Calendar = .current) {
        provider?.onShowMuted = { [weak self] ids in self?.showMuted(ids) }
        var decisions = Dictionary(uniqueKeysWithValues: cards.cards.compactMap { card in
            card.muteDecision.map { (card.id, $0) }
        })
        decisions.merge(provider?.mutedDecisions ?? [:], uniquingKeysWith: { _, current in current })
        let groups = Dictionary(grouping: cards.cards.filter { card in
            guard let decision = decisions[card.id] else { return false }
            return decision.source != .dailyBudget && decision.releasedAt == nil
        }) {
            calendar.startOfDay(for: decisions[$0.id]?.decidedAt ?? $0.createdAt)
        }
        let summaryIDs = Set(groups.keys.map { "rating-muted-\(Int($0.timeIntervalSince1970))" })
        for notice in cards.notices where notice.id.hasPrefix("rating-muted-") && !summaryIDs.contains(notice.id) {
            _ = cards.removeNotice(id: notice.id)
        }
        for (day, values) in groups {
            guard let end = calendar.date(bySettingHour: dailyHour(), minute: 0, second: 0, of: day), end <= now else { continue }
            let ids = values.map(\.id), noticeID = "rating-muted-\(Int(day.timeIntervalSince1970))"
            let summary = "\(ids.count) muted \(ids.count == 1 ? "message" : "messages") today"
            if let existing = cards.notices.first(where: { $0.id == noticeID }) {
                if existing.summary != summary { _ = cards.updateNotice(id: noticeID) { $0.summary = summary } }
            } else {
                _ = cards.recordNotice(.init(id: noticeID, kind: .messageRating, createdAt: end, summary: summary, actionTitle: "Show"))
            }
            installSummaryAction(id: noticeID, cardIDs: ids)
        }
        for suggestion in suggestions {
            let id = "rating-suggestion-" + suggestion.id
            if !cards.notices.contains(where: { $0.id == id }) {
                _ = cards.recordNotice(.init(id: id, kind: .messageRating, createdAt: now,
                    summary: "Getting a lot of " + suggestion.kindLabel, actionTitle: "Rate them", secondaryTitle: "Not now"))
            }
            cards.setNoticeAction(id: id) { [weak self] in
                guard let self, let cardID = suggestion.exampleCardID, let card = self.cards.card(id: cardID) else { return }
                self.begin(card); self.openCard(cardID)
            }
            cards.setSecondaryNoticeAction(id: id) { [weak self] in self?.dismiss(suggestion) }
        }
        let activeSuggestions = Set(suggestions.map { "rating-suggestion-" + $0.id })
        for notice in cards.notices where notice.id.hasPrefix("rating-suggestion-") && !activeSuggestions.contains(notice.id) {
            _ = cards.removeNotice(id: notice.id)
        }
        dailyTask?.cancel(); dailyTask = nil
        guard observing, !groups.isEmpty,
              let next = calendar.nextDate(after: now, matching: DateComponents(hour: dailyHour(), minute: 0), matchingPolicy: .nextTime) else { return }
        dailyTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow))) } catch { return }
            self?.reconcile()
        }
    }
    private func installSummaryAction(id: String, cardIDs: [String]) {
        cards.setNoticeAction(id: id) { [weak self] in
            self?.showMuted(cardIDs)
            self?.installSummaryAction(id: id, cardIDs: cardIDs)
        }
    }
    private(set) var hasOpenedRow: Bool
    private(set) var focusRequest: UInt64 = 0
    private(set) var focusedRatingCardID: String?
    private(set) var keyboardCardID: String?
    func noteKeyboardFocus(cardID: String, focused: Bool) {
        if focused { keyboardCardID = cardID }
        else if keyboardCardID == cardID { keyboardCardID = nil }
    }
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored var dailyHour: () -> Int = { 21 }
    @ObservationIgnored private let source: () -> (any MessageRatingsProviding)?
    @ObservationIgnored let cards: CardStore
    @ObservationIgnored var openCard: (String) -> Void = { _ in }
    @ObservationIgnored var openSettings: () -> Void = {}

    init(cards: CardStore, defaults: UserDefaults? = nil, source: @escaping () -> (any MessageRatingsProviding)? = { nil }) {
        self.cards = cards; self.source = source; self.defaults = defaults
        hasOpenedRow = defaults?.bool(forKey: "ratings.openedRow") ?? false
    }
    var provider: (any MessageRatingsProviding)? { source() }
    var ratings: [MessageRating] { provider?.ratings ?? [] }
    var suggestions: [RatingSuggestion] { provider?.ratingSuggestions ?? [] }
    var revision: UInt64 { provider?.ratingsRevision ?? 0 }
    var startupError: String?
    var error: String? { startupError ?? provider?.ratingsError }
    static func eligible(_ card: Card) -> Bool {
        card.origin == .unprompted && [.message, .question, .content].contains(card.kind)
    }
    func canRate(_ card: Card) -> Bool { Self.eligible(card) && provider != nil }
    /// Only a rating mutes. A decision from the removed daily limit is never shown as one.
    func decision(_ card: Card) -> CardMuteDecision? {
        let decision = provider?.mutedDecisions[card.id] ?? card.muteDecision
        return decision?.source == .dailyBudget ? nil : decision
    }
    func isHeld(_ card: Card) -> Bool {
        guard let decision = decision(card) else { return false }
        return decision.releasedAt == nil && card.origin != .reply
    }
    func isCollapsed(_ card: Card) -> Bool { isHeld(card) && !expandedMuted.contains(card.id) }
    var newestUnpromptedID: String? { cards.cards.last(where: Self.eligible)?.id }
    func currentRating(_ card: Card) -> MessageRating? {
        ratings.last { $0.exampleCardID == card.id }
            ?? ratings.first { $0.id == decision(card)?.ratingID }
            ?? ratings.first { $0.scope == .kind && MessageRatingStore.kindKey($0.kindLabel) == MessageRatingStore.kindKey(card.about ?? "") }
    }
    static func defaultLabel(_ card: Card) -> String {
        if let label = card.about, !label.isEmpty { return label }
        if let title = card.title, !title.isEmpty { return String(title.prefix(60)) }
        return String(card.body.prefix(30)) + (card.body.count > 30 ? "…" : "")
    }
    func toggle(_ card: Card) { if drafts[card.id] != nil { cancel(card.id) } else { begin(card) } }
    func begin(_ card: Card) {
        guard canRate(card), !busy.contains(card.id) else { return }
        let current = currentRating(card)
        drafts[card.id] = Draft(label: current?.kindLabel ?? Self.defaultLabel(card), scope: current?.scope ?? .kind)
        hasOpenedRow = true; defaults?.set(true, forKey: "ratings.openedRow")
        if isHeld(card) { expandedMuted.insert(card.id) }
        focusedRatingCardID = card.id; focusRequest &+= 1
        confirmations[card.id] = nil; errors[card.id] = nil
    }
    func cancel(_ id: String) { guard !busy.contains(id) else { return }; drafts[id] = nil; errors[id] = nil; if focusedRatingCardID == id { focusedRatingCardID = nil } }
    func setLabel(_ value: String, id: String) { drafts[id]?.label = String(value.prefix(60)) }
    func setScope(_ value: MessageRatingScope, id: String) { drafts[id]?.scope = value }
    func editLabel(_ id: String) {
        guard var draft = drafts[id] else { return }
        draft.originalLabel = draft.label; draft.editingLabel = true; drafts[id] = draft
    }
    func finishLabel(_ id: String, cancel: Bool = false) {
        guard let draft = drafts[id] else { return }
        if cancel || draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drafts[id]?.label = draft.originalLabel ?? draft.label }
        drafts[id]?.editingLabel = false; drafts[id]?.originalLabel = nil
    }
    func hide(_ id: String) { expandedMuted.remove(id); cancel(id) }
    func show(_ id: String) { expandedMuted.insert(id); provider?.ratingCardOpened(id: id) }
    func showMuted(_ ids: [String]) {
        for id in ids { show(id) }
        if let first = cards.cards.first(where: { ids.contains($0.id) }) { openCard(first.id) }
    }
    func changeRating(_ card: Card) {
        begin(card)
        if let decision = decision(card) { drafts[card.id]?.label = decision.kindLabel }
    }
    func confirmation(for card: Card) -> Confirmation? {
        if let decision = decision(card), decision.releasedAt != nil {
            return .init(text: "Shown. Zeus won't count this as \(decision.kindLabel)", receipt: provider?.ratingUndo(for: card.id))
        }
        guard !isHeld(card), let rating = currentRating(card) else { return nil }
        return .init(text: Self.confirmation(rating.rating, label: rating.kindLabel, scope: rating.scope), receipt: provider?.ratingUndo(for: rating.id))
    }
    func rate(_ value: MessageRatingValue, card: Card) async {
        guard canRate(card), let draft = drafts[card.id], let provider else { return }
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { errors[card.id] = "Give this kind a name."; return }
        await perform(card.id) {
            let receipt: MessageRatingUndo
            if let current = self.currentRating(card), current.scope == draft.scope || current.exampleCardID == card.id {
                receipt = try await provider.update(id: current.id, rating: value, scope: draft.scope, label: label)
            } else { receipt = try await provider.rate(cardID: card.id, rating: value, scope: draft.scope, label: label) }
            self.confirmations[card.id] = .init(text: Self.confirmation(value, label: label, scope: draft.scope), receipt: receipt)
            self.drafts[card.id] = nil
        }
    }
    func canUndo(_ id: String) -> Bool { provider?.ratingUndo(for: id) != nil }
    func undo(_ id: String) async {
        guard let provider else { return }
        let receipt = cards.card(id: id).flatMap { confirmation(for: $0)?.receipt } ?? provider.ratingUndo(for: id)
        guard let receipt else { return }
        await perform(id) { try await provider.undoRating(receipt); self.confirmations[id] = nil; self.expandedMuted.remove(id) }
    }
    func correct(_ card: Card) async {
        guard let provider else { return }
        await perform(card.id) { _ = try await provider.correctMuted(cardID: card.id); self.expandedMuted.insert(card.id) }
    }
    func update(_ rating: MessageRating, value: MessageRatingValue? = nil, label: String? = nil) async {
        guard let provider else { return }
        let newLabel = (label ?? rating.kindLabel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLabel.isEmpty, newLabel.count <= 60 else { errors[rating.id] = "Use a kind name of 1–60 characters."; return }
        await perform(rating.id) {
            let receipt = try await provider.update(id: rating.id, rating: value ?? rating.rating, scope: rating.scope, label: newLabel)
            self.confirmations[rating.id] = .init(text: "Rating updated", receipt: receipt)
        }
    }
    func remove(_ rating: MessageRating) async {
        guard let provider else { return }
        await perform(rating.id) {
            let receipt = try await provider.remove(id: rating.id)
            self.confirmations[rating.id] = .init(text: "Rating removed", receipt: receipt)
        }
    }
    func dismiss(_ suggestion: RatingSuggestion) {
        do { try provider?.dismissRatingSuggestion(id: suggestion.id); errors[suggestion.id] = nil }
        catch { errors[suggestion.id] = error.localizedDescription }
    }
    func lastMatched(_ rating: MessageRating) -> Date? {
        let decisions = provider?.mutedDecisions.values.filter { $0.ratingID == rating.id }.map(\.decidedAt) ?? []
        let exact = cards.cards.filter { $0.origin == .unprompted && MessageRatingStore.kindKey($0.about ?? "") == MessageRatingStore.kindKey(rating.kindLabel) }.map(\.createdAt)
        return (decisions + exact).filter { $0 >= rating.createdAt }.max()
    }
    private func perform(_ id: String, operation: () async throws -> Void) async {
        guard busy.insert(id).inserted else { return }
        errors[id] = nil
        defer { busy.remove(id) }
        do { try await operation() }
        catch { errors[id] = error.localizedDescription }
    }
    static func label(_ value: MessageRatingValue) -> String {
        switch value { case .up: "More like this"; case .neutral: "Neutral"; case .down: "Stop these" }
    }
    static func confirmation(_ value: MessageRatingValue, label: String, scope: MessageRatingScope) -> String {
        if scope == .justThisOne {
            switch value { case .up: return "More like this one"; case .neutral: return "Only when I need to know, this one"; case .down: return "Not this one" }
        }
        switch value { case .up: return "More like this: \(label)"; case .neutral: return "Only when I need to know: \(label)"; case .down: return "Stopped: \(label)" }
    }
}
