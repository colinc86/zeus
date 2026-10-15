import Foundation
import Observation

/// Independent consent and scope per observation level. No persisted choice means off.
struct ObservationPolicy: Codable, Equatable, Sendable {
    enum Scope: String, Codable, CaseIterable, Sendable {
        case exceptPrivate, chosenApps
        var title: String { self == .exceptPrivate ? "Everywhere except my private list" : "Only in apps I choose" }
    }
    var enabled = false
    var consented = false
    var scope = Scope.exceptPrivate
    var apps: [ExcludedApp] = []
    var retentionDays = 90

    /// The shared private list always wins, including in allow-list mode. Unknown apps fail closed.
    func allows(bundleID: String?, name: String?, privateApps: [ExcludedApp]) -> Bool {
        guard let bundleID, !bundleID.isEmpty,
              !privateApps.contains(where: { $0.matches(bundleID: bundleID, name: name) }) else { return false }
        let listed = apps.contains { $0.matches(bundleID: bundleID, name: name) }
        return scope == .chosenApps ? listed : !listed
    }
}

@MainActor @Observable
final class ObservationSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private var policies: [Int: ObservationPolicy]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        policies = defaults.data(forKey: "learn.levelPolicies").flatMap { try? JSONDecoder().decode([Int: ObservationPolicy].self, from: $0) } ?? [:]
    }
    func policy(_ level: Int) -> ObservationPolicy { policies[level] ?? ObservationPolicy() }
    func set(_ level: Int, _ policy: ObservationPolicy) {
        var policy = policy
        policy.retentionDays = min(365, max(1, policy.retentionDays))
        // Future levels cannot be enabled by imported defaults or a generic control.
        if level > 2 { policy.enabled = false }
        policies[level] = policy
        if let data = try? JSONEncoder().encode(policies) { defaults.set(data, forKey: "learn.levelPolicies") }
    }
    func edit(_ level: Int, _ body: (inout ObservationPolicy) -> Void) {
        var value = policy(level); body(&value); set(level, value)
    }
}
