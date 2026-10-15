import Foundation
import Observation
import ZeusProtocol

/// Presentation reads runtime delivery state; removing a pending item is never treated as a receipt.
@MainActor @Observable final class LearningDeliveryModel {
    @ObservationIgnored private let source: () -> (any LearningDeliveryPresenting)?
    @ObservationIgnored private let cards: CardStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored var receivedDeliveryIDs: () -> Set<String>? = { [] }
    @ObservationIgnored var openTerminal: @MainActor () -> Void = {}
    @ObservationIgnored var restartAssistant: @MainActor () -> Void = {}
    @ObservationIgnored var openFolder: @MainActor () -> Void = {}
    @ObservationIgnored var replaceTemplate: @MainActor () -> Void = {}
    @ObservationIgnored var agentName: () -> String = { "your assistant" }
    @ObservationIgnored var conversationID: () -> String? = { nil }
    @ObservationIgnored var canStart: () -> Bool = { false }
    @ObservationIgnored var startAssistant: @MainActor () -> Void = {}
    @ObservationIgnored var setupError: () -> String? = { nil }
    @ObservationIgnored private var awaitingSetupRestart = false
    @ObservationIgnored private var setupConversation: String?
    private(set) var restartError: String?
    @ObservationIgnored var setupProgress: () -> String? = { nil }
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var setupDates: [String: Date] = [:]
    private(set) var pending: [PendingLearningDelivery] = []
    private(set) var holds: [DeliveryHold] = []
    private(set) var stale = ManagedSetupStaleness()
    private(set) var now: Date

    init(cards: CardStore, source: @escaping () -> (any LearningDeliveryPresenting)?, clock: @escaping () -> Date = Date.init) {
        self.cards = cards; self.source = source; self.clock = clock; now = clock()
    }
    func start() { guard !observing else { return }; observing = true; observationGeneration &+= 1; reconcile(); observe() }
    func stop() { observing = false; observationGeneration &+= 1; boundary?.cancel(); boundary = nil }
    isolated deinit { boundary?.cancel() }
    var matureHolds: [DeliveryHold] { holds.filter { now.timeIntervalSince($0.since) >= 600 } }
    var menuStatus: String? {
        guard !matureHolds.isEmpty else { return nil }
        if matureHolds.contains(where: { $0.reason == .draft }) { return "Waiting on unsent text in Terminal" }
        return "Waiting to deliver to \(agentName())"
    }
    var setupSummary: String? {
        if let progress = setupProgress() { return progress }
        if let restartError { return restartError }
        if stale.template && stale.templateEdited { return "Your assistant's instructions are older than Zeus's template" }
        if stale.tools || stale.template { return "Zeus has new \(ManagedAssistantModel.setupContent(stale)) for your assistant" }
        return nil
    }
    func reconcile() {
        now = clock()
        let received = receivedDeliveryIDs()
        pending = (source()?.pendingLearningDeliveries ?? []).filter { received?.contains($0.id) != true }
        holds = (source()?.deliveryHolds ?? []).filter { received?.contains($0.id) != true }
            .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since < $1.since }
        stale = source()?.managedSetupStale ?? .init()
        if setupConversation != conversationID() {
            setupConversation = conversationID(); awaitingSetupRestart = false; restartError = nil
        }
        if setupProgress() != nil { awaitingSetupRestart = true; restartError = nil }
        else if awaitingSetupRestart {
            awaitingSetupRestart = false
            if let error = setupError() {
                let text = error.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                restartError = "Couldn't restart \(agentName()). " + text + (text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? "" : ".")
            }
        }
        if !stale.tools && !stale.template { restartError = nil }
        for item in pending {
            // An unreadable journal cannot prove that an older Sent notice was false.
            if received == nil && cards.notices.contains(where: { $0.id == "n_" + item.id }) { continue }
            let notice: ThreadNotice
            if item.kind == .reflection {
                notice = .init(id: "n_" + item.id, kind: .learning, createdAt: item.preparedAt, summary: "Daily reflection ready", actionTitle: "View", detail: item.text)
            } else {
                notice = Self.preparedNotice(.init(id: item.id, kind: item.learningKind ?? .digest, createdAt: item.preparedAt, text: item.text))
            }
            _ = cards.recordLearningNotice(.init(id: notice.id, kind: .reflection, createdAt: notice.createdAt, summary: notice.summary, actionTitle: notice.actionTitle, detail: notice.detail, ruleID: nil), action: nil)
        }
        reconcileNotices()
        boundary?.cancel(); boundary = nil
        let early = holds.map { $0.since.addingTimeInterval(600) }.filter { $0 > now }.min()
        let next = holds.contains(where: { $0.reason == .busy }) ? min(early ?? .distantFuture, now.addingTimeInterval(60)) : early
        if let next {
            boundary = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.01, next.timeIntervalSince(self?.clock() ?? next)))) } catch { return }
                self?.reconcile()
            }
        }
    }
    private func reconcileNotices() {
        guard source() != nil else { return }
        let active = matureHolds.filter { [.reflection, .learning].contains($0.kind) }
            .filter { $0.reason != .olderSetup }
        let ids = Set(active.map { "learning-delivery-hold:" + $0.id })
        for notice in cards.notices where notice.id.hasPrefix("learning-delivery-hold:") && !ids.contains(notice.id) {
            _ = cards.removeNotice(id: notice.id)
        }
        for hold in active {
            let title: String? = switch hold.reason {
            case .draft, .busy: "Open in Terminal"
            case .disconnected: canStart() ? "Start Assistant" : nil
            case .olderSetup: nil
            }
            let action: (@MainActor () -> Void)? = title == nil ? nil : { @MainActor [weak self] in
                guard let self, self.source()?.deliveryHolds.contains(where: { $0.id == hold.id && $0.reason == hold.reason }) == true else { return }
                if hold.reason == .disconnected { if self.canStart() { self.startAssistant() } } else { self.openTerminal() }
                self.reconcile()
            }
            _ = cards.recordLearningNotice(.init(id: "learning-delivery-hold:" + hold.id, kind: .reflection,
                createdAt: hold.since, summary: "Zeus is waiting to deliver to your assistant: " + Self.reason(hold, now: now),
                actionTitle: title, detail: nil, ruleID: nil), action: action,
                secondaryTitle: hold.reason == .draft ? "Don't send" : nil,
                secondary: hold.reason == .draft ? { @MainActor [weak self] in self?.source()?.requestLearningDeliveryCancellation(deliveryID: hold.id); self?.reconcile() } : nil)
        }
        guard let conversation = conversationID() else {
            for notice in cards.notices where notice.id.hasPrefix("managed-setup-update:") { _ = cards.removeNotice(id: notice.id) }
            return
        }
        let setupID = "managed-setup-update:" + conversation
        for notice in cards.notices where notice.id.hasPrefix("managed-setup-update:") && notice.id != setupID {
            _ = cards.removeNotice(id: notice.id)
        }
        setupDates[setupID] = setupDates[setupID] ?? cards.notices.first { $0.id == setupID }?.createdAt ?? now
        if let summary = setupSummary, !cards.hasOpenQuestion {
            let edited = stale.template && stale.templateEdited && setupProgress() == nil
            let pending = setupProgress() != nil
            _ = cards.recordLearningNotice(.init(id: setupID, kind: .reflection, createdAt: setupDates[setupID] ?? now, summary: summary,
                actionTitle: pending ? nil : edited ? "Open Folder" : "Restart assistant", detail: nil, ruleID: nil),
                action: pending ? nil : { @MainActor [weak self] in
                    guard let self, self.conversationID() == conversation, !self.cards.hasOpenQuestion else { return }
                    if edited { self.openFolder() } else { self.restartAssistant() }
                    self.reconcile()
                },
                secondaryTitle: edited ? "Use the new template" : nil,
                secondary: edited ? { @MainActor [weak self] in
                    guard let self, self.conversationID() == conversation, !self.cards.hasOpenQuestion else { return }
                    self.replaceTemplate(); self.reconcile()
                } : nil)
        } else { _ = cards.removeNotice(id: setupID) }
    }
    static func reason(_ hold: DeliveryHold, now: Date) -> String {
        switch hold.reason {
        case .draft: return "unsent text in Terminal"
        case .busy:
            let minutes = max(10, Int(now.timeIntervalSince(hold.since) / 60))
            return "it's been busy for " + (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        case .disconnected: return "it isn't connected"
        case .olderSetup: return "it was started with an older setup"
        }
    }
    static func preparedNotice(_ learning: Learning) -> ThreadNotice {
        var notice = ThreadNotice.learning(learning)
        if learning.kind == .digest { notice.summary = "Daily summary ready for your assistant" }
        else {
            let prefix = "Sent a note: "
            notice.summary = notice.summary.hasPrefix(prefix) ? "Note ready: " + notice.summary.dropFirst(prefix.count) : "Note ready for your assistant"
        }
        return notice
    }
    private func observe() {
        guard observing else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = cards.hasOpenQuestion; _ = receivedDeliveryIDs(); _ = conversationID(); _ = setupProgress(); _ = setupError(); _ = canStart()
            _ = source()?.pendingLearningDeliveries; _ = source()?.deliveryHolds; _ = source()?.managedSetupStale
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in guard let self, self.observing, self.observationGeneration == generation else { return }; self.reconcile(); self.observe() }
        }
    }
}
