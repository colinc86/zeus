import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ZeusProtocol

extension ZeusRuntime: LearningJournalAccessControlling {
    func callJournalTool(_ args: ToolArguments, sessionKey: String, deferResultCommit: Bool) async throws -> ToolResult {
        guard let journal = learningJournal, let redactor = learningRedactor else { throw ToolArgumentError("The journal isn't available.") }
        guard journalAnswerReceipts.count < 40 else { throw ToolArgumentError("Zeus needs to finish saving earlier journal answers first.") }
        let now = clock.now
        journalCalls.removeAll { now.timeIntervalSince($0) >= 3600 }
        var auditQuery = JournalQuery(); auditQuery.kinds = [.sentToAssistant]; auditQuery.from = now.addingTimeInterval(-3600); auditQuery.limit = 100_000
        let recorded = try journal.items(matching: auditQuery).filter { $0.payload.value.details["kind"] == "journal_answer" }.count
        guard max(journalCalls.count, recorded) < 20 else { throw ToolArgumentError("The journal allows 20 calls an hour. Please wait before asking again.") }
        journalCalls.append(now)
        let query = try args.string("query") ?? ""
        guard query.count <= 256 else { throw ToolArgumentError("Use at most 256 characters for the journal query.") }
        let to = try journalDate(args.string("to")) ?? now
        let from = try journalDate(args.string("from")) ?? to.addingTimeInterval(-86400)
        guard from <= to, to.timeIntervalSince(from) <= 7 * 86400 else { throw ToolArgumentError("That range is longer than 7 days or ends before it starts.") }
        let limit = try args.number("limit") ?? 20
        guard limit.rounded() == limit, (1...50).contains(limit) else { throw ToolArgumentError("limit must be a whole number from 1 to 50.") }
        let raw = try args.bool("raw", default: false)
        let names: [String: JournalLevel] = ["activity": .activity, "focus": .focus, "screen": .screen, "typing": .typed]
        var wanted = Set(names.values)
        if args.values["kinds"] != nil {
            wanted = []
            for value in try args.array("kinds") {
                guard case .string(let name) = value, let level = names[name] else { throw ToolArgumentError("kinds must contain activity, focus, screen or typing.") }; wanted.insert(level)
            }
        }
        let token = generation, sessionID = sessions.first { $0.sessionKey == sessionKey }?.id
        let safeQuery = await redactor.redact(query)
        guard running, generation == token, isAdmitted(sessionKey), sessionID != nil,
              sessions.first(where: { $0.sessionKey == sessionKey })?.id == sessionID else { throw CancellationError() }
        // All reads and result construction occur synchronously after the final policy check.
        let policy = journalAccessPolicy(), levels = wanted.intersection(policy.enabledLevels)
        var request = JournalQuery(); request.from = from; request.to = to; request.levels = levels
        request.kinds = [.activity, .focus, .description, .typedText]; request.limit = 100_000
        let candidates = levels.isEmpty ? [] : try journal.items(matching: request).sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }
        var items: [JSONValue] = [], bytes = 0
        for item in candidates {
            let payload = item.payload.value
            let text: String
            switch item.level {
            case .typed: guard let topic = payload.topic else { continue }; text = topic
            case .screen: text = payload.description
            case .focus: text = payload.text ?? payload.description
            case .activity: text = payload.description
            }
            let words = raw && policy.enabledLevels.contains(.typed) && item.level == .typed ? payload.text : nil
            // Searching summaries must not reveal the existence of an unpermitted word in retained typing.
            guard query.isEmpty || (text + (words.map { " " + $0 } ?? "")).localizedStandardContains(query) else { continue }
            var fields: [String: JSONValue] = ["id": .string(item.id), "time": .string(item.time.ISO8601Format()),
                "app": .string(item.app ?? ""), "kind": .string(names.first { $0.value == item.level }?.key ?? "activity"), "text": .string(text)]
            if let words { fields["words"] = .string(words) }
            if item.level == .screen, raw, policy.enabledLevels.contains(.screen), let frameID = payload.details["frame_id"],
               let store = journal as? any FrameJournalStoring, let frame = try store.frame(id: frameID),
               let picture = Self.journalPicture(frame.value.heic) { fields["picture"] = picture }
            let itemValue = JSONValue.object(fields), size = try ZeusJSON.encoder().encode(itemValue).count
            // Bound the entire answer, including image bytes; never split or invent stored text.
            guard size <= 400_000 else { continue }
            if bytes + size > 400_000 { break }
            items.append(itemValue); bytes += size
            if items.count >= Int(limit) { break }
        }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = learningCalendar; format.timeZone = learningCalendar.timeZone; format.dateFormat = "EEE d MMM HH:mm"
        let range = format.string(from: from) + "–" + format.string(from: to)
        let statuses: JSONValue = .object(["screen": .string(raw ? (levels.contains(.screen) && policy.enabledLevels.contains(.screen) ? "allowed" : "not allowed") : "not requested"),
                                           "typing": .string(raw ? (levels.contains(.typed) && policy.enabledLevels.contains(.typed) ? "allowed" : "not allowed") : "not requested")])
        let value: JSONValue = ["answer_id": .string("journal_answer_" + UUID().uuidString), "query": .string(safeQuery.value),
            "from": .string(from.ISO8601Format()), "to": .string(to.ISO8601Format()), "range": .string(range),
            "items": .array(items), "raw": statuses, "raw_requested": .bool(raw),
            "off": .array(wanted.subtracting(policy.enabledLevels).sorted { $0.rawValue < $1.rawValue }.compactMap { level in names.first { $0.value == level }.map { .string($0.key) } }),
            "note": .string(policy.enabledLevels.isEmpty ? "Learn from me is off." : "This answer is logged in What Zeus Kept › Sent to your assistant.")]
        let output = result(value)
        if case .string(let id) = value["answer_id"] { journalAnswerReceipts[id] = (output, sessionKey, journal.revision, false) }
        if !deferResultCommit { recordJournalAnswerReceipt(output, sessionKey: sessionKey) }
        return output
    }
    private func journalDate(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = learningCalendar.timeZone
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; local.isLenient = false
        if let date = local.date(from: value) { return date }
        throw ToolArgumentError("Use an ISO 8601 date and time for from and to.")
    }
    /// Only covered stored bytes enter this converter. Smaller JPEGs fit the bounded wire and exact ledger row.
    static func journalPicture(_ covered: Data) -> JSONValue? {
        guard let source = CGImageSourceCreateWithData(covered as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(target), data.length <= 150_000 else { return nil }
        return ["mimeType": "image/jpeg", "data": .string((data as Data).base64EncodedString())]
    }
    func recordJournalAnswerReceipt(_ output: ToolResult, sessionKey: String) {
        guard let journal = learningJournal, !output.isError, let value = output.structured,
              case .string(let id) = value["answer_id"], let pending = journalAnswerReceipts[id], pending.1 == sessionKey,
              pending.0 == output, case .array(let items) = value["items"] else { return }
        journalAnswerReceipts[id]?.3 = true
        do {
            var query = JournalQuery(); query.limit = 100_000
            let retained = try journal.items(matching: query)
            if retained.contains(where: { $0.id == id }) { journalAnswerReceipts.removeValue(forKey: id); return }
            // Forgetting source records while a result is in flight must not put their content back into the ledger.
            if items.isEmpty && pending.2 != journal.revision { journalAnswerReceipts.removeValue(forKey: id); return }
            let ids = Set(retained.map(\.id))
            guard items.allSatisfy({ if case .string(let key) = $0["id"] { return ids.contains(key) }; return false }) else { journalAnswerReceipts.removeValue(forKey: id); return }
            let agent = sessions.first { $0.sessionKey == sessionKey }?.agent.rawValue ?? "other"
            let label = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"][agent] ?? "Assistant"
            let identity = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
            func text(_ key: String) -> String { if case .string(let text) = value[key] { return text }; return "" }
            func status(_ key: String) -> String { if case .string(let status) = value["raw"]?[key] { return status }; return "not requested" }
            let pictures = items.filter { $0["picture"] != nil }.count, words = items.contains { $0["words"] != nil }
            let detail = ["kind": "journal_answer", "answer_id": id, "query": text("query"), "from": text("from"), "to": text("to"), "range": text("range"),
                "item_count": String(items.count), "raw_requested": value["raw_requested"] == true ? "true" : "false", "raw_screen": status("screen"), "raw_typing": status("typing"),
                "pictures": String(pictures), "includes_words": words ? "true" : "false", "agent": agent,
                "sessionLabel": label + (managedController.sessionKey == sessionKey ? " · Zeus" : " · Assistant"), "sessionID": identity]
            try journal.append(.init(id: id, time: clock.now, level: .activity, kind: .sentToAssistant,
                payload: .init(.init(description: "Journal answer", text: output.text, details: detail))))
            journalAnswerReceipts.removeValue(forKey: id)
            showJournalAnswerNotice(value, at: clock.now)
        } catch { learningError = "Zeus couldn't save a journal answer receipt. It will try again." }
    }
    func reconnectJournalAnswerNotices() {
        guard let journal = learningJournal else { return }
        var query = JournalQuery(); query.kinds = [.sentToAssistant]; query.limit = 100_000
        do {
            journalNoticeWindow = nil
            let answers = try journal.items(matching: query).filter { $0.payload.value.details["kind"] == "journal_answer" }.suffix(200)
            for item in answers {
                guard let text = item.payload.value.text, let value = try? ZeusJSON.decoder().decode(JSONValue.self, from: Data(text.utf8)) else { continue }
                showJournalAnswerNotice(value, at: item.time)
            }
        } catch { learningError = "Zeus couldn't reconnect journal answer notices." }
    }
    private func showJournalAnswerNotice(_ value: JSONValue, at date: Date) {
        guard case .string(let id) = value["answer_id"], case .array(let items) = value["items"] else { return }
        func text(_ key: String) -> String { if case .string(let text) = value[key] { return text }; return "" }
        let pictures = items.filter { $0["picture"] != nil }.count, words = items.contains { $0["words"] != nil }
        var summary = "Looked at your journal"
        if pictures > 0 { summary += ", including \(pictures) pictures" }
        else if words { summary += ", including your words" }
        summary += items.isEmpty ? ": nothing for " + text("range") : ": " + text("range")
        if value["raw_requested"] == true && pictures == 0 && !words && !items.isEmpty { summary += " (descriptions only)" }
        let group: (Date, String, Int)
        if let previous = journalNoticeWindow, date.timeIntervalSince(previous.0) < 600 { group = (previous.0, previous.1, previous.2 + 1); summary = "Looked at your journal \(group.2) times" }
        else { group = (date, id, 1) }
        journalNoticeWindow = group
        (cards as? any LearningNoticeRecording)?.recordLearningNotice(.init(id: group.1, kind: .reflection, createdAt: group.0,
            summary: summary, actionTitle: items.isEmpty && group.2 == 1 ? nil : "View", detail: nil, ruleID: nil),
            action: { [weak self] in self?.onViewJournalAnswer?(id) })
    }

}
