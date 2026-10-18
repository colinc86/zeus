import Foundation
import ZeusProtocol

/// A persisted delivery plus the answer data needed by polling after card history is pruned.
struct DeliveryRecord: Codable, Sendable, Equatable {
    var delivery: Delivery
    var response: CardResponse?
    /// Raw compose input for polling, independent of the human-readable push prefix.
    var userText: String?
    /// First observed absence of this reply's target; survives app restarts.
    var disconnectedAt: Date?
    /// Unbound compose input waiting for the first eligible assistant. In this private
    /// state sessionKey is empty; it is assigned durably before any push or polling result.
    var awaitingAssistant: Bool?
    /// Actual connector receipt, distinct from an attempt or model acknowledgment.
    var transportDeliveredAt: Date?
    /// A completed paste recovery gets the ordinary 3-minute ack grace, even
    /// when old verification failures had already exhausted the attempt budget.
    var tmuxPasteRecoveredAt: Date?
    /// Durable delivery tombstone; never fabricate ackedAt on discard.
    var discardedAt: Date?
    enum QueueReasonSource: String, Codable, Sendable { case managedGate, nativeRoute }
    /// UI caption ownership is private ledger state, never agent delivery/pin metadata.
    var queueReasonSource: QueueReasonSource?
    var queueReason: String?
    var stateUpdatedAt: Date?
    var holdSince: Date?
    var holdReason: String?
    var isPending: Bool { delivery.ackedAt == nil && discardedAt == nil }
}

/// Durable transactions: write an atomic snapshot before publishing any in-memory mutation.
/// The private versioned file format is independent of the bridge wire contract.
@MainActor
final class DeliveryLedger {
    private struct Snapshot: Codable {
        var version = 2
        var records: [DeliveryRecord]
    }
    private let location: URL
    private(set) var records: [DeliveryRecord]
    /// Called only after an atomic write commits; consumers observe durable truth.
    var onChange: (([DeliveryRecord]) -> Void)?

    init(location: URL) throws {
        self.location = location
        if FileManager.default.fileExists(atPath: location.path) {
            let snapshot = try ZeusJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: location))
            guard [1, 2].contains(snapshot.version), Set(snapshot.records.map { $0.delivery.id }).count == snapshot.records.count else {
                throw DeliveryLedgerError.invalidSnapshot
            }
            records = snapshot.records
        } else { records = [] }
        try transact { _ in }
    }

    func record(id: String) -> DeliveryRecord? { records.first { $0.delivery.id == id } }
    /// 0.1.0 compose input was addressed to the assistant using a cwd/pane key.
    /// Unbind it durably at app load; normal assistant binding then chooses the
    /// current session (or waits for one) without guessing an agent PID.
    func prepareLegacyUserMessages() throws {
        try transact { records in
            for index in records.indices {
                let delivery = records[index].delivery
                guard delivery.kind == .userMessage, records[index].isPending,
                      !delivery.sessionKey.isEmpty, !Self.hasProcessIdentity(delivery.sessionKey) else { continue }
                records[index].delivery.sessionKey = ""
                records[index].awaitingAssistant = true
                // Failure of the old destination must not exhaust the new assistant's retry budget.
                records[index].delivery.attempts = 0
                records[index].delivery.lastAttemptAt = nil
                records[index].delivery.failedAt = nil
            }
        }
    }

    /// Old size-only holds get another attempt under the pointer transport. Other
    /// failures and already-mutated native input retain their existing recovery rules.
    func preparePointerDeliveries() throws {
        try transact { records in
            for i in records.indices where records[i].isPending
                && records[i].delivery.meta["tmux_paste_destination"] == nil
                && records[i].queueReason == ConnectorError.inputTooLong.localizedDescription {
                records[i].delivery.attempts = 0
                records[i].delivery.failedAt = nil
                records[i].delivery.lastAttemptAt = nil
                records[i].queueReason = nil
                records[i].holdSince = nil; records[i].holdReason = nil
            }
        }
    }

    private static func hasProcessIdentity(_ key: String) -> Bool {
        guard let separator = key.lastIndex(of: "#") else { return false }
        let parts = key[key.index(after: separator)...].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let pid = Int(parts[0]), pid > 0, let start = UInt64(parts[1]), start > 0 else { return false }
        return true
    }

    func insert(_ record: DeliveryRecord) throws {
        guard self.record(id: record.delivery.id) == nil else { throw DeliveryLedgerError.duplicateID }
        try transact { $0.append(record) }
    }
    func update(id: String, _ mutate: (inout Delivery) -> Void) throws {
        try transact { records in
            guard let index = records.firstIndex(where: { $0.delivery.id == id }) else { return }
            mutate(&records[index].delivery)
        }
    }
    func updateRecord(id: String, _ mutate: (inout DeliveryRecord) -> Void) throws {
        try transact { records in
            guard let index = records.firstIndex(where: { $0.delivery.id == id }) else { return }
            mutate(&records[index])
        }
    }
    /// Supersession and expiry commit together before the runtime publishes notices.
    func discardLearningRequests(_ reasons: [String: String], at date: Date) throws {
        try transact { records in
            for index in records.indices {
                guard records[index].isPending, let reason = reasons[records[index].delivery.id] else { continue }
                records[index].discardedAt = date
                records[index].stateUpdatedAt = date
                if let typed = DiscardedLearningDelivery.Reason(rawValue: reason) {
                    records[index].queueReason = DiscardedLearningDelivery.caption(kind: records[index].delivery.kind, reason: typed)
                }
                records[index].delivery.meta["discard_reason"] = reason
                records[index].delivery.meta.removeValue(forKey: "tmux_paste_destination")
            }
        }
    }

    /// Acks only the requesting target session; repeated acknowledgments are harmless.
    func acknowledge(ids: Set<String>, sessionKey: String, at date: Date) throws -> [String] {
        let matched = records.filter { $0.discardedAt == nil && $0.delivery.sessionKey == sessionKey && ids.contains($0.delivery.id) }.map { $0.delivery.id }
        guard !matched.isEmpty else { return [] }
        try transact { records in
            for index in records.indices where matched.contains(records[index].delivery.id) && records[index].delivery.ackedAt == nil {
                records[index].delivery.ackedAt = date
                records[index].stateUpdatedAt = date
                records[index].queueReason = nil
            }
        }
        return matched
    }
    /// Atomic bulk changes for rerouting, user-requested retry and discard.
    func mutateRecords(_ mutate: (inout [DeliveryRecord]) -> Void) throws { try transact(mutate) }

    private func transact(_ mutate: (inout [DeliveryRecord]) -> Void) throws {
        var next = records
        mutate(&next)
        // Keep the newest 500 records plus every pending item, including exhausted
        // input. Stable insertion order breaks timestamp ties (ISO dates may round).
        let newest = Set(next.indices.sorted {
            next[$0].delivery.createdAt == next[$1].delivery.createdAt
                ? $0 > $1 : next[$0].delivery.createdAt > next[$1].delivery.createdAt
        }.prefix(500))
        next = next.enumerated().filter { newest.contains($0.offset) || $0.element.isPending }.map(\.element)
        guard next != records else { return }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try ZeusJSON.encoder().encode(Snapshot(records: next))
        try data.write(to: location, options: .atomic)
        records = next
        onChange?(next)
    }
}

/// Invalid persisted ledger state; start fails rather than overwriting unreadable delivery data.
enum DeliveryLedgerError: Error { case invalidSnapshot, duplicateID }
