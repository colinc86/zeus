import Foundation
import ZeusProtocol

/// Optional presentation origin, independent of ordinary unread-card alerts.
@MainActor
protocol ManagedBlockingPresenting: AnyObject {
    /// Nil clears only managed blocking, preserving agent overrides and unread state.
    func setManagedBlock(_ detail: String?)
}

/// UI-facing seam forwarding. Observation follows the controller's published state.
extension ZeusRuntime: ManagedSessionControlling {
    var managedStatus: ManagedSessionStatus { managedController.managedStatus }
    var managedTmuxSessionName: String? { managedController.managedTmuxSessionName }
    var managedAttachCommand: String? { managedController.managedAttachCommand }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] { managedController.permissionModes(for: agent) }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { managedController.managedRequirementsProblem(for: agent) }
    /// The app composition supplies this method to ManagedAssistantModel.createFolder.
    func createDefaultFolder() throws -> URL { try managedController.createDefaultFolder() }
    func startManagedSession() { managedController.startManagedSession() }
    func stopManagedSession() { managedController.stopManagedSession() }
    func restartManagedSession() { managedController.restartManagedSession() }
    func startNewManagedConversation() { managedController.startNewManagedConversation() }
    func openManagedSessionInTerminal() { managedController.openManagedSessionInTerminal() }
}

import ZeusDesign

extension ZeusRuntime {
    static let managedCardPrefix = "managed-block_"
    func managedBlockedCopy() -> (title: String, body: String, action: String) {
        let agent = managedController.record?.conversation?.agent ?? .other
        let name = agent == .claude ? "Claude Code" : agent == .codex ? "Codex" : "OpenCode"
        let dialog = managedController.blockedDialog ?? ""
        var copy = ZeusManagedCopy.blockedCard(agent: name, dialog: dialog)
        if dialog.lowercased().contains("warning: loading development channels") {
            copy.body = "Claude Code is asking you to confirm Zeus's message channel. Choose “I am using this for local development” (option 1) in Terminal to continue. Zeus never chooses for you.\n\n" + copy.body
        }
        return copy
    }
    enum ManagedBlockEnd { case answered, stopped, crashed, unavailable, disabled }
    var managedBlockEnd: ManagedBlockEnd? {
        if managedController.mayResolveBlockedCard { return .answered }
        switch managedStatus {
        case .stopped: return .stopped
        case .restarting: return .crashed
        case .failed: return .unavailable
        case .off where !managedController.enabled: return .disabled
        default: return nil
        }
    }

    /// One card per continuous block. Terminal is an action, never an agent answer.
    func updateManagedPresentation() {
        if case .blocked = managedController.managedStatus {
            if managedBlockedCardID == nil || cards.card(id: managedBlockedCardID ?? "")?.status != .open {
                let copy = managedBlockedCopy()
                let id = managedBlockedCardID.flatMap { cards.card(id: $0) == nil ? $0 : nil }
                    ?? (Self.managedCardPrefix + UUID().uuidString)
                managedBlockedCardID = id
                cards.add(Card(id: id, kind: .content, title: copy.title, body: copy.body,
                    options: [.init(id: "open-terminal", label: copy.action, style: .primary)],
                    priority: .high, mood: .alert, sessionKey: managedController.sessionKey,
                    createdAt: clock.now, updatedAt: clock.now))
            }
            if let id = managedBlockedCardID, let card = cards.card(id: id), card.status == .open {
                let copy = managedBlockedCopy()
                if card.title != copy.title || card.body != copy.body {
                    cards.update(id: id) { $0.title = copy.title; $0.body = copy.body }
                }
            }
            if let id = managedBlockedCardID, let key = managedController.sessionKey, cards.card(id: id)?.sessionKey == nil {
                cards.update(id: id) { $0.sessionKey = key }
            }
            if let presentation = status as? any ManagedBlockingPresenting {
                presentation.setManagedBlock("Waiting for you in Terminal")
            } else {
                status.setOverride(.alert, detail: "Waiting for you in Terminal", progress: nil, ttl: 10)
            }
        } else if let id = managedBlockedCardID, let end = managedBlockEnd {
            if resolveManagedCard(id, end: end) { managedBlockedCardID = nil }
            if let presentation = status as? any ManagedBlockingPresenting { presentation.setManagedBlock(nil) }
            else { status.clearOverride() }
        }
    }
    @discardableResult func resolveManagedCard(_ id: String, end: ManagedBlockEnd = .answered) -> Bool {
        let body: String
        switch end {
        case .answered: body = ZeusManagedCopy.blockedCardResolved
        case .stopped: body = "The assistant stopped before this prompt was answered."
        case .crashed: body = "The assistant quit before this prompt was answered."
        case .unavailable: body = "Zeus couldn't confirm that this prompt was answered."
        case .disabled: body = "Zeus stopped managing this prompt before it was answered."
        }
        return cards.update(id: id) {
            $0.status = .answered; $0.response = nil; $0.options = []; $0.input = nil
            $0.title = end == .answered ? ZeusManagedCopy.blockedCardResolvedTitle : "Terminal prompt closed"
            $0.body = body; $0.mood = nil; $0.priority = .low
        }
    }
    /// Consumed before persistence by M4 stores. Legacy stores are restored synchronously;
    /// no response intent or delivery is ever created for this option.
    func handleManagedAction(_ card: Card, response: CardResponse) -> Bool {
        guard card.id.hasPrefix(Self.managedCardPrefix) else { return false }
        if card.id == managedBlockedCardID {
            if card.status == .answered { cards.update(id: card.id) { $0.response = nil; $0.status = .open } }
        }
        if response.optionID == "open-terminal", managedAttachCommand != nil { openManagedSessionInTerminal() }
        // The action is navigation, never evidence that a prompt was answered.
        updateManagedPresentation()
        return true
    }

    /// Bootstrap channel evidence with an ack-only control item, never a user message.
    /// One probe per process lifetime. Unanswered probes simply leave tmux selected.
    func probeManagedChannel() {
        guard managedController.canAcceptInput, let key = managedController.sessionKey,
              let session = sessions.first(where: { $0.sessionKey == key }), session.agent == .claude,
              session.supportsChannel, let bridge = bridges[key], managedChannelProbes[key] == nil else { return }
        let id = "managed-ready_" + UUID().uuidString
        managedChannelProbes[key] = id
        let token = generation
        managedProbeTasks[key] = Task { [weak self] in
            try? await bridge.push(.init(deliveryID: id,
                content: "Zeus channel readiness check. Call zeus_ack with delivery_ids [\"\(id)\"]. Do not post a card or reply to this check.",
                meta: ["kind": "readiness", "delivery_id": id]))
            guard let self, self.generation == token else { return }
            self.managedProbeTasks.removeValue(forKey: key)
        }
    }
    /// Only an explicit zeus_ack of a probe or actual pushed item proves a channel.
    /// Polling or a pane ack after fallback does not prove channel readiness.
    func confirmManagedChannel(ids: Set<String>, sessionKey: String) -> String? {
        guard sessionKey == managedController.sessionKey else { return nil }
        let probe = managedChannelProbes[sessionKey]
        let probeAck = probe.map { ids.contains($0) } ?? false
        let pushedAck = (ledger?.records ?? []).contains {
            $0.delivery.sessionKey == sessionKey && ids.contains($0.delivery.id)
                && $0.delivery.meta["managed_channel_sent_at"] != nil
                && $0.delivery.meta["managed_channel_fallback"] != "true"
        }
        if probeAck || pushedAck { managedChannelReady.insert(sessionKey) }
        return probeAck ? probe : nil
    }
    /// Durable deadline survives app relaunch; same delivery ID is used on the pane.
    func expireManagedChannels() {
        let due = (ledger?.records ?? []).contains {
            guard $0.isPending, $0.delivery.meta["managed_channel_fallback"] != "true",
                  let raw = $0.delivery.meta["managed_channel_sent_at"], let sent = Double(raw) else { return false }
            return clock.now.timeIntervalSince1970 >= sent + 30
        }
        guard due else { return }
        do {
            var expired: Set<String> = []
            try ledger?.mutateRecords { records in
                for index in records.indices where records[index].isPending {
                    let delivery = records[index].delivery
                    guard delivery.meta["managed_channel_fallback"] != "true",
                          let raw = delivery.meta["managed_channel_sent_at"], let sent = Double(raw),
                          clock.now.timeIntervalSince1970 >= sent + 30 else { continue }
                    records[index].delivery.meta["managed_channel_fallback"] = "true"
                    expired.insert(delivery.sessionKey)
                }
            }
            managedChannelReady.subtract(expired)
        } catch { storageProblem = "Couldn't save the managed channel fallback: \(error.localizedDescription)" }
    }
}
