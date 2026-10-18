import Foundation
import ZeusProtocol

/// IDs only; no captured activity or message text is stored in the noise counter.
@MainActor final class ProactiveState {
    struct Snapshot: Codable {
        var budgetCards: [String: Set<String>] = [:]
    }
    private let url: URL
    private(set) var value: Snapshot
    init(url: URL) throws {
        self.url = url
        value = FileManager.default.fileExists(atPath: url.path)
            ? try ZeusJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url)) : Snapshot()
    }
    func count(day: String) -> Int { value.budgetCards[day]?.count ?? 0 }
    func record(cardID: String, day: String) throws {
        var next = value
        next.budgetCards[day, default: []].insert(cardID)
        // Keep a month of counters for clock/time-zone changes, without retaining content.
        for key in next.budgetCards.keys.sorted().dropLast(31) { next.budgetCards.removeValue(forKey: key) }
        guard next.budgetCards != value.budgetCards else { return }
        try ZeusJSON.encoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        value = next
    }
}
