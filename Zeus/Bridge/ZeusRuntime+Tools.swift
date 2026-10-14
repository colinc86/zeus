import Foundation
import ZeusProtocol

extension ZeusRuntime {
    /// Shared tool boundary for wire dispatch and in-memory seam tests.
    func callTool(_ name: String, arguments: JSONValue, sessionKey: String, deferResultCommit: Bool = false) async -> ToolResult {
        guard running else { return toolError("Zeus runtime isn't running.") }
        if let error = pendingUpdateErrors.removeValue(forKey: sessionKey) { return toolError(error) }
        activeToolCalls[sessionKey, default: 0] += 1
        let token = generation
        defer {
            if generation == token {
                let remaining = max(0, (activeToolCalls[sessionKey] ?? 1) - 1)
                if remaining == 0 { activeToolCalls.removeValue(forKey: sessionKey) }
                else { activeToolCalls[sessionKey] = remaining }
            }
        }
        defer { retainRuntimeHistory() }
        if ZeusMCP.tools.contains(where: { $0.name == name }) { noteAgentActivity(sessionKey: sessionKey) }
        do {
            let args = try ToolArguments(arguments)
            if ["zeus_say", "zeus_ask", "zeus_present", "zeus_update_card", "zeus_dismiss"].contains(name) {
                try checkCardPersistence()
            }
            // A later card_id argument is an ack even if the requested mutation fails validation.
            if case .string(let cardID) = args.values["card_id"] {
                let ids = Set((ledger?.records ?? []).filter { $0.delivery.cardID == cardID }.map { $0.delivery.id })
                _ = try acknowledge(ids: ids, sessionKey: sessionKey)
            }
            guard let definition = ZeusMCP.tools.first(where: { $0.name == name }),
                  case .object(let properties) = definition.inputSchema["properties"] else { throw ToolArgumentError("Unknown tool: \(name)") }
            let unexpected = Set(args.values.keys).subtracting(properties.keys).sorted()
            guard unexpected.isEmpty else {
                throw ToolArgumentError("Unexpected arguments for \(name): \(unexpected.joined(separator: ", ")). Allowed: \(properties.keys.sorted().joined(separator: ", ")).")
            }
            if Self.appToolNames.contains(name) {
                return try await callAppTool(name, args: args, sessionKey: sessionKey, deferResultCommit: deferResultCommit)
            }
            switch name {
            case "zeus_say":
                let now = clock.now
                let card = Card(kind: .message, title: try args.string("title"), body: try args.requiredString("text"),
                                attachments: try args.attachments(), priority: try args.enumeration("priority", as: Card.Priority.self) ?? .normal,
                                mood: try args.enumeration("mood", as: AvatarState.self), sessionKey: sessionKey,
                                createdAt: now, updatedAt: now, expiresAt: try args.ttl().map { now.addingTimeInterval($0) })
                endAssistantActivity(sessionKey: sessionKey)
                try addCard(card)
                return result(["card_id": .string(card.id)])
            case "zeus_ask": return try await ask(args, sessionKey: sessionKey, deferResultCommit: deferResultCommit)
            case "zeus_present":
                let actions = try args.options("actions")
                let allowText = try args.bool("allow_text", default: false)
                let now = clock.now
                let card = Card(kind: .content, title: try args.requiredString("title"), body: try args.requiredString("body"),
                                options: actions, input: allowText ? InputSpec() : nil, attachments: try args.attachments(),
                                priority: try args.enumeration("priority", as: Card.Priority.self) ?? .normal,
                                mood: try args.enumeration("mood", as: AvatarState.self), sessionKey: sessionKey, createdAt: now, updatedAt: now)
                endAssistantActivity(sessionKey: sessionKey)
                try addCard(card)
                return result(["card_id": .string(card.id)])
            case "zeus_update_card":
                let id = try args.requiredString("card_id")
                try validateAgentCard(id, sessionKey: sessionKey)
                let title = try args.string("title"), text = try args.string("text"), append = try args.string("append_text")
                let progress = try args.progress()
                let updated = cards.update(id: id) { card in
                    if let title { card.title = title }
                    if let text { card.body = text }
                    if let append { card.body += append }
                    if args.values["progress"] != nil { card.progress = progress }
                }
                try checkCardPersistence()
                guard updated, let card = cards.card(id: id) else { return missingCardResult(id) }
                return result(["ok": true, "title": card.title.map(JSONValue.string) ?? .null,
                               "progress": card.progress.map(JSONValue.number) ?? .null, "status": .string(card.status.rawValue)])
            case "zeus_dismiss":
                let id = try args.requiredString("card_id")
                try validateAgentCard(id, sessionKey: sessionKey)
                let exists = cards.card(id: id) != nil
                if exists { cards.dismiss(id: id); finishWaiter(id: id, result: pendingResult(id)) }
                try checkCardPersistence()
                return exists ? result(["ok": true]) : missingCardResult(id)
            case "zeus_set_status":
                let state = try args.requiredString("state")
                let detail = try args.string("detail"), progress = try args.progress(), ttl = try args.ttl(default: 600) ?? 600
                if state == "auto" { status.clearOverride(); endAssistantActivity(sessionKey: sessionKey) }
                else {
                    guard let avatarState = AvatarState(rawValue: state) else { throw ToolArgumentError("Unknown state: \(state)") }
                    status.setOverride(avatarState, detail: detail, progress: progress, ttl: ttl)
                    if avatarState == .thinking || avatarState == .working {
                        noteWorkingActivity(sessionKey: sessionKey, detail: detail, progress: progress, ttl: ttl)
                    } else { endAssistantActivity(sessionKey: sessionKey) }
                }
                return result(["ok": true])
            case "zeus_get_responses":
                bindWaitingUserMessages()
                let pending = (ledger?.records ?? []).filter { $0.delivery.sessionKey == sessionKey && $0.isPending }
                let batch = try pollingBatch(pending)
                if !deferResultCommit { _ = try acknowledge(ids: Set(batch.map { $0.delivery.id }), sessionKey: sessionKey) }
                let transport = transport(for: sessionKey)
                let mode: String = transport?.0 is ChannelDeliveryConnector ? "channel" : (transport == nil ? "polling" : routing.deliveryMethod.rawValue)
                let active = transport.map { connector, session, context in
                    if connector is OpenCodeConnector { return context.openCodeSessionID(for: session.sessionKey) != nil }
                    if connector is TmuxConnector, session.tmuxPane != nil { return context.tmuxSocketPath != nil }
                    return true
                } ?? false
                return result(["items": .array(batch.map(pollItem)), "delivery_mode": .string(mode), "push_active": .bool(active)])
            case "zeus_ack":
                guard args.values["delivery_ids"] != nil else { throw ToolArgumentError("Missing delivery_ids") }
                let ids = try args.array("delivery_ids").map { value in
                    guard case .string(let id) = value else { throw ToolArgumentError("delivery_ids must contain strings") }; return id
                }
                let probe = confirmManagedChannel(ids: Set(ids), sessionKey: sessionKey)
                var acked = try acknowledge(ids: Set(ids), sessionKey: sessionKey)
                if let probe { acked.append(probe) }
                return result(["acked": .array(acked.map(JSONValue.string))])
            case "zeus_list_characters":
                let available = characters.availableCharacters.map { character -> JSONValue in
                    ["id": .string(character.id), "name": .string(character.name), "description": .string(character.summary)]
                }
                return result(["current": .string(characters.currentCharacterID), "characters": .array(available)])
            default: throw ToolArgumentError("Unknown tool: \(name)")
            }
        } catch let error as AppControlError { return toolError(error.agentMessage) }
        catch { return toolError(error.localizedDescription) }
    }

    private func ask(_ args: ToolArguments, sessionKey: String, deferResultCommit: Bool) async throws -> ToolResult {
        let options = try args.options("options")
        let allowText = try args.bool("allow_text", default: options.isEmpty)
        let placeholder = try args.string("placeholder"), multiline = try args.bool("multiline", default: false)
        let wait = min(600, max(0, try args.number("wait_seconds") ?? 45))
        let now = clock.now
        let card = Card(kind: .question, title: try args.string("title"), body: try args.requiredString("text"), options: options,
                        input: allowText ? .init(placeholder: placeholder, multiline: multiline) : nil,
                        priority: try args.enumeration("priority", as: Card.Priority.self) ?? .normal,
                        sessionKey: sessionKey, createdAt: now, updatedAt: now)
        endAssistantActivity(sessionKey: sessionKey)
        appQuestionIDs.insert(card.id)
        try responseJournal?.prepare(card.id)
        guard wait > 0, !Task.isCancelled else { try addCard(card); return pendingResult(card.id) }
        let deadline = now.addingTimeInterval(wait)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let clock = self.clock
                let timer = Task { [weak self] in
                    do { try await clock.sleep(until: deadline) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.finishWaiter(id: card.id, result: self.pendingResult(card.id))
                }
                // Register before add: a store is allowed to report an immediate UI answer.
                waiters[card.id] = .init(sessionKey: sessionKey, deadline: deadline, continuation: continuation, timer: timer, deferResultCommit: deferResultCommit,
                                         deliveryID: responseJournal?.intents.first(where: { $0.cardID == card.id })?.deliveryID ?? "ask:\(card.id)",
                                         activityToken: activityTokens[sessionKey], sessionID: sessions.first(where: { $0.sessionKey == sessionKey })?.id)
                do { try addCard(card) }
                catch { finishWaiter(id: card.id, result: toolError(error.localizedDescription)) }
                if Task.isCancelled { finishWaiter(id: card.id, result: pendingResult(card.id)) }
            }
        } onCancel: { Task { @MainActor [weak self] in guard let self else { return }; self.finishWaiter(id: card.id, result: self.pendingResult(card.id)) } }
    }
    func checkCardPersistence() throws {
        if let message = (cards as? any CardPersistenceReporting)?.persistenceError { throw ToolArgumentError(message) }
    }
    private func validateAgentCard(_ id: String, sessionKey: String) throws {
        guard let card = cards.card(id: id) else { return }
        guard !id.hasPrefix(Self.managedCardPrefix) else { throw ToolArgumentError("Agent tools cannot change or dismiss native prompts or local Terminal notices.") }
        // A rerouted answer grants its receiving session access to that card,
        // even though history preserves the original creator (CONTRACT §4).
        let handedOff = (ledger?.records ?? []).contains { $0.delivery.cardID == id && $0.delivery.sessionKey == sessionKey }
        guard card.sessionKey == sessionKey || handedOff else { throw ToolArgumentError("Agent tools cannot read or change another session's card.") }
    }
    private func addCard(_ card: Card) throws {
        if !card.options.isEmpty || card.input != nil { try responseJournal?.prepare(card.id) }
        cards.add(card)
        try checkCardPersistence()
    }
    /// Budget the complete doubly encoded result (text plus structured JSON),
    /// leaving space for wire/MCP correlation and quiet-hours metadata.
    private func pollingBatch(_ pending: [DeliveryRecord]) throws -> [DeliveryRecord] {
        var batch: [DeliveryRecord] = []
        var bytes = 1024
        for record in pending {
            let item = pollItem(record)
            let raw = try ZeusJSON.encoder().encode(item)
            let escaped = try ZeusJSON.encoder().encode(JSONValue.string(String(decoding: raw, as: UTF8.self)))
            let cost = raw.count + escaped.count + 4
            if bytes + cost > 4 * 1024 * 1024 {
                if batch.isEmpty { throw ToolArgumentError("Saved response is too large for one tool result; it remains pending. delivery_id=\(record.delivery.id)") }
                break
            }
            bytes += cost; batch.append(record)
        }
        return batch
    }
    private func pollItem(_ record: DeliveryRecord) -> JSONValue {
        let delivery = record.delivery
        var item: [String: JSONValue] = ["delivery_id": .string(delivery.id), "kind": .string(delivery.kind.rawValue),
            "text": .string((delivery.meta["earlier_session"] == nil ? "" : Self.earlierSessionPrefix + " ") + (record.response?.text ?? record.response?.summary ?? record.userText ?? delivery.content)),
            "created_at": .string(delivery.createdAt.ISO8601Format(.init(includingFractionalSeconds: true)))]
        if let cardID = delivery.cardID { item["card_id"] = .string(cardID) }
        if let option = record.response?.optionID { item["option_id"] = .string(option) }
        if let label = record.response?.optionLabel { item["option_label"] = .string(label) }
        return .object(item)
    }
    private func missingCardResult(_ id: String) -> ToolResult {
        var failure = result(["ok": false, "error": .string("No card \(id) (it may have been removed from history).")])
        failure.isError = true
        return failure
    }
    private func toolError(_ message: String) -> ToolResult {
        var failure = result(["error": .string(message)])
        failure.isError = true
        return failure
    }
}
