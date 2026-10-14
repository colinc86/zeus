import Foundation
import ZeusProtocol

struct ManagedInputSample: Sendable {
    let pane: ManagedPane
    let agent: AgentKind
    let snapshot: ManagedPaneSnapshot
    let capturedAt: Date
    let input: TmuxInputSnapshot?
    let classification: ManagedPaneClassifier.Classification
    let draftText: String?
    init(pane: ManagedPane, agent: AgentKind, snapshot: ManagedPaneSnapshot, capturedAt: Date) {
        self.pane = pane; self.agent = agent; self.snapshot = snapshot; self.capturedAt = capturedAt
        input = .init(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8))
        classification = ManagedPaneClassifier.classify(snapshot, agent: agent)
        draftText = input?.humanDraftText
    }
}

/// A confirmation authorizes only these queued deliveries, never later arrivals.
struct ManagedDraftCancellation: Equatable, Sendable, Identifiable {
    let id: UUID
    let cardID: String
    let deliveryIDs: Set<String>
    var count: Int { deliveryIDs.count }
}

/// Optional app capability; no localized-caption matching or arbitrary Terminal input.
@MainActor
protocol ManagedDraftAlertControlling: AnyObject {
    var managedDraftStatusDetail: String? { get }
    var managedDraftCancellation: ManagedDraftCancellation? { get }
    func respondToDraftCancellation(id: UUID, confirmed: Bool)
}

struct ManagedDraftEpisode {
    let pane: ManagedPane
    var cardID: String?
    var waitingSince: Date?
    var text: String
}

extension ZeusRuntime: ManagedDraftAlertControlling {
    static let managedDraftPrefix = managedCardPrefix + "draft_"
    var managedDraftStatusDetail: String? { managedDraftWaiting ? "Waiting on unsent text in Terminal" : nil }

    /// Last positive input proof. Posting requires a fresh sample separately;
    /// expiry alone never releases a known human draft for a new delivery.
    func genuineManagedDraft() -> (ManagedInputSample, String)? {
        guard running, managedController.enabled, let sample = managedController.latestInputSample,
              sample.pane == managedController.record?.pane, !sample.pane.dead,
              let input = sample.input, let text = sample.draftText else { return nil }
        guard case .running = managedStatus else { return nil }
        switch sample.classification {
        case .blocked, .working: return nil
        case .idle, .unknown: break // OpenCode keeps a bounded composer even with its caret at the draft's end.
        }
        let destination = URL(fileURLWithPath: sample.pane.socket).resolvingSymlinksInPath().standardizedFileURL.path + ":" + sample.pane.id
        for record in ledger?.records ?? [] where record.isPending && record.delivery.meta["tmux_paste_destination"] == destination {
            let paste = AgentInjectionText.format(record.delivery)
            if input.containsOnlyClaudePaste(paste) || input.containsOnlyCodexPaste(paste) { return nil }
            // OpenCode's recovery verifier also has hidden/collapsed pastes. A
            // journaled mutation owns this pane until the connector settles it.
            if sample.agent == .opencode { return nil }
        }
        // A receipt can clear the journal before the next 3-second pane sample.
        // Do not relabel that older screenshot of our just-submitted text as human input.
        for record in ledger?.records ?? [] where record.delivery.sessionKey == managedController.sessionKey
            && record.transportDeliveredAt.map({ sample.capturedAt <= $0 }) == true {
            let paste = AgentInjectionText.format(record.delivery)
            if input.containsOnlyClaudePaste(paste) || input.containsOnlyCodexPaste(paste) { return nil }
        }
        return (sample, text)
    }

    func draftQueuedRecords() -> [DeliveryRecord] {
        (ledger?.records ?? []).filter(isDraftQueued)
    }
    func isDraftQueued(_ record: DeliveryRecord) -> Bool {
        running && managedController.enabled && record.isPending && record.transportDeliveredAt == nil
            && sends[record.delivery.id] == nil && record.delivery.meta["tmux_paste_destination"] == nil
            && record.delivery.meta["opencode_destination_validated"] != "true"
            && ((record.awaitingAssistant == true && record.delivery.kind == .userMessage)
                || record.delivery.sessionKey == managedController.sessionKey)
    }

    /// Read-only gate; a journaled paste always retains its recovery path.
    func heldByManagedDraft(_ record: DeliveryRecord) -> Bool {
        isDraftQueued(record) && genuineManagedDraft() != nil
    }

    func refreshManagedDraftAlert() {
        let queued = draftQueuedRecords()
        let draft = genuineManagedDraft()
        if !queued.isEmpty, let (sample, _) = draft, clock.now.timeIntervalSince(sample.capturedAt) > 6 { return }
        guard let (sample, text) = draft else {
            if !queued.isEmpty, let sample = managedController.latestInputSample,
               sample.pane == managedDraftEpisode?.pane, clock.now.timeIntervalSince(sample.capturedAt) > 6 { return }
            // Unknown/repainting samples cannot prove a previously reported draft
            // cleared. Keep its episode, but never create an alert from stale proof.
            if !queued.isEmpty, let sample = managedController.latestInputSample,
               sample.pane == managedDraftEpisode?.pane,
               sample.classification == .unknown,
               sample.input?.isEmpty != true { return }
            if !queued.isEmpty, managedController.latestInputSample == nil, managedController.enabled,
               recoveredDraftCardID != nil, managedStatus == .starting || managedStatus == .off { return }
            let empty = managedController.latestInputSample?.input?.isEmpty == true
            resolveManagedDraftAlert(body: queued.isEmpty ? "No queued messages remain."
                : empty ? "Terminal input is clear. Zeus can send your queued messages."
                : "Zeus is no longer waiting on this Terminal draft. Your messages remain saved.")
            managedDraftEpisode = nil; recoveredDraftCardID = nil
            return
        }
        if managedDraftEpisode?.pane != sample.pane {
            let recovered = recoveredDraftCardID.flatMap { cards.card(id: $0) }
            let matching = managedController.sessionKey != nil && recovered?.sessionKey == managedController.sessionKey
            if managedDraftEpisode != nil || (recovered != nil && !matching) {
                resolveManagedDraftAlert(body: "The assistant's Terminal changed. Your messages remain saved.")
            }
            managedDraftEpisode = .init(pane: sample.pane, cardID: matching ? recovered?.id : nil,
                waitingSince: nil, text: text)
            recoveredDraftCardID = nil
        }
        managedDraftEpisode?.text = text
        guard !queued.isEmpty else {
            resolveManagedDraftAlert(body: "No queued messages remain.")
            managedDraftEpisode?.waitingSince = nil
            return
        }
        managedDraftWaiting = true
        if managedDraftEpisode?.waitingSince == nil { managedDraftEpisode?.waitingSince = clock.now }
        guard let since = managedDraftEpisode?.waitingSince,
              clock.now.timeIntervalSince(since) >= 20
                || managedDraftEpisode?.cardID.flatMap({ cards.card(id: $0) })?.status == .open else { return }
        let id = managedDraftEpisode?.cardID ?? (Self.managedDraftPrefix + UUID().uuidString)
        let count = queued.count
        let preview = String((text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces).prefix(80))
        let body = preview + "\n\nZeus is holding \(count) \(count == 1 ? "message" : "messages") until it's sent or cleared."
        let options: [CardOption] = [.init(id: "open-terminal", label: "Open in Terminal", style: .primary),
            .init(id: "cancel-draft-queue", label: count == 1 ? "Cancel queued message" : "Cancel queued messages", style: .secondary)]
        managedDraftEpisode?.cardID = id
        if cards.card(id: id) == nil {
            cards.add(Card(id: id, kind: .content, title: "Your assistant has unsent text in Terminal", body: body, options: options,
                priority: .high, mood: .alert, sessionKey: managedController.sessionKey, createdAt: clock.now, updatedAt: clock.now))
        } else if let old = cards.card(id: id), old.body != body || old.status != .open || old.sessionKey != managedController.sessionKey {
            cards.update(id: id) {
                $0.status = .open; $0.response = nil; $0.input = nil; $0.options = options
                $0.title = "Your assistant has unsent text in Terminal"
                $0.body = body; $0.priority = .high; $0.mood = .alert; $0.sessionKey = managedController.sessionKey
            }
        }
        if cards.card(id: id)?.status == .open { managedDraftAlertCardID = id }
        updateManagedPresentation()
    }

    var managedDraftDeadline: Date? {
        guard managedDraftAlertCardID == nil, genuineManagedDraft() != nil, !draftQueuedRecords().isEmpty,
              let since = managedDraftEpisode?.waitingSince, since.addingTimeInterval(20) > clock.now else { return nil }
        return since.addingTimeInterval(20)
    }

    func resolveManagedDraftAlert(body: String) {
        let hadAlert = managedDraftAlertCardID != nil
        if let id = managedDraftAlertCardID ?? recoveredDraftCardID, let card = cards.card(id: id), card.status == .open {
            cards.update(id: id) { $0.status = .answered; $0.response = nil; $0.input = nil; $0.options = []; $0.priority = .low; $0.mood = nil; $0.body = body; $0.title = "Terminal draft notice closed" }
        }
        managedDraftAlertCardID = nil; managedDraftWaiting = false; managedDraftCancellation = nil
        if hadAlert {
            if let presentation = status as? any ManagedBlockingPresenting { presentation.setManagedBlock(nil) }
            else { status.clearOverride() }
        }
        updateManagedPresentation()
    }

    func handleManagedDraftAction(_ card: Card, response: CardResponse) -> Bool {
        guard card.id.hasPrefix(Self.managedDraftPrefix) else { return false }
        guard running, card.id == managedDraftAlertCardID, response.text?.isEmpty != false,
              genuineManagedDraft() != nil else { return true }
        if response.optionID == "open-terminal" { openManagedSessionInTerminal() }
        else if response.optionID == "cancel-draft-queue" {
            let ids = Set(draftQueuedRecords().map { $0.delivery.id })
            if ids.count == 1 { cancelDraftQueue(ids) }
            else if ids.count > 1 { managedDraftCancellation = .init(id: UUID(), cardID: card.id, deliveryIDs: ids) }
        }
        return true
    }

    func respondToDraftCancellation(id: UUID, confirmed: Bool) {
        guard let request = managedDraftCancellation, request.id == id else { return }
        managedDraftCancellation = nil
        guard confirmed, request.cardID == managedDraftAlertCardID, genuineManagedDraft() != nil else { return }
        cancelDraftQueue(request.deliveryIDs)
    }

    /// Durable scoped discard. No broad queue discard, native keys, or fabricated acknowledgments.
    func cancelDraftQueue(_ requested: Set<String>) {
        let ids = requested.intersection(Set(draftQueuedRecords().map { $0.delivery.id }))
        guard !ids.isEmpty else { return }
        do {
            let cardIDs = Set(draftQueuedRecords().filter { ids.contains($0.delivery.id) }.compactMap { $0.delivery.cardID })
            for cardID in cardIDs { try responseJournal?.complete(cardID) }
            try ledger?.mutateRecords { records in
                for index in records.indices where ids.contains(records[index].delivery.id) {
                    records[index].discardedAt = clock.now; records[index].stateUpdatedAt = clock.now; records[index].queueReason = nil
                }
            }
            for cardID in cardIDs {
                cards.update(id: cardID) { $0.body += "\n\nYour queued answer was cancelled." }
            }
            for id in ids { deferredSends.removeValue(forKey: id) }
            discardAssistantActivities(deliveryIDs: ids)
            processDueDeliveries()
        } catch { storageProblem = "Couldn't cancel the queued messages: \(error.localizedDescription)"; refreshProblem() }
    }
}
