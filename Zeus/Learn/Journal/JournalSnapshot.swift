import Foundation

/// A validated local-viewer snapshot. Expiry is a publication boundary, even without a new store revision.
struct JournalSnapshot: Sendable {
    let revision: UInt64
    let items: [JournalItem]
    let expiresAt: Date?
}

/// Optional bulk reader; file decryption and decoding must not run on the main actor.
@MainActor protocol JournalSnapshotProviding: JournalStore {
    func journalSnapshot() async throws -> JournalSnapshot
}

struct JournalSnapshotPartition: Sendable {
    let url: URL
    let items: [JournalItem]
}

/// Reads immutable inputs only; retention, transaction recovery and publication remain store-owned.
enum JournalSnapshotReader {
    static func read(_ urls: [URL], secret: Data) async throws -> [JournalSnapshotPartition] {
        let task = Task.detached(priority: .utility) {
            try urls.map { url in
                try Task.checkCancellation()
                return JournalSnapshotPartition(url: url,
                    items: try LearningEncryption.decode([JournalItem].self, bytes: Data(contentsOf: url), url: url, secret: secret))
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
