import Foundation
import CryptoKit

/// A value snapshot shared by outbound builders and their final delivery checks.
struct LearningOutboundPolicy: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        var name: String
        var bundleIDs: [String]
        func matches(bundleID: String, name other: String?) -> Bool {
            bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
                || other.map { $0.caseInsensitiveCompare(name) == .orderedSame } == true
        }
    }
    struct Scope: Codable, Equatable, Sendable {
        var level: JournalLevel
        var chosenApps: [App]?
    }
    var scopes: [Scope]
    var privateApps: [App]

    var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    func allows(_ item: JournalItem) -> Bool {
        allows(level: item.level, app: item.app, name: JournalAppName.displayName(item))
    }
    func allows(level: JournalLevel, app: String?, name: String?) -> Bool {
        guard let scope = scopes.first(where: { $0.level == level }) else { return false }
        guard let app, !app.isEmpty else {
            // Anonymous timing/outcome events carry no application content.
            return level == .activity
        }
        guard !privateApps.contains(where: { $0.matches(bundleID: app, name: name) }) else { return false }
        return scope.chosenApps.map { $0.contains { $0.matches(bundleID: app, name: name) } } ?? true
    }
    /// The items `allows`, deciding each distinct level, app and recorded app name once.
    /// Weeks of journal hold a few dozen apps; matching every row against every chosen app stalled the main thread.
    func allowing(_ items: [JournalItem]) -> [JournalItem] {
        struct Key: Hashable { let level: JournalLevel, app: String?, name: String?, appName: String? }
        var verdicts: [Key: Bool] = [:]
        return items.filter { item in
            let details = item.payload.value.details
            let key = Key(level: item.level, app: item.app, name: details["name"], appName: details["appName"])
            if let verdict = verdicts[key] { return verdict }
            let verdict = allows(item); verdicts[key] = verdict
            return verdict
        }
    }
}

extension Array where Element == JournalItem {
    /// All items when there is no outbound policy, otherwise the ones it allows.
    func allowed(by policy: LearningOutboundPolicy?) -> [JournalItem] { policy?.allowing(self) ?? self }
}

@MainActor protocol LearningOutboundPolicyControlling: AnyObject {
    var outboundLearningPolicy: () -> LearningOutboundPolicy? { get set }
}

/// Refreshes unread summaries synchronously before a delivery or a tool can consume them.
@MainActor protocol LearningDigestPreparing: AnyObject {
    func prepareDigestsForCurrentPolicy()
    func digestMetadata(id: String) -> [String: String]
}
