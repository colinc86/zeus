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

    var permitsSafariDetails: Bool { scope == .chosenApps && apps.contains { $0.matches(bundleID: "com.apple.Safari", name: nil) } }

    /// The shared private list always wins, including in allow-list mode. Unknown apps fail closed.
    func allows(bundleID: String?, name: String?, privateApps: [ExcludedApp]) -> Bool {
        guard let bundleID, !bundleID.isEmpty,
              !privateApps.contains(where: { $0.matches(bundleID: bundleID, name: name) }) else { return false }
        let listed = apps.contains { $0.matches(bundleID: bundleID, name: name) }
        return scope == .chosenApps ? listed : true
    }
}

@MainActor @Observable
final class ObservationSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private var policies: [Int: ObservationPolicy]
    private var rawLevels: Set<Int>
    func rawAllowed(_ level: Int) -> Bool { [3, 4].contains(level) && rawLevels.contains(level) }
    func setRawAllowed(_ allowed: Bool, level: Int) {
        guard [3, 4].contains(level) else { return }
        if allowed { rawLevels.insert(level) } else { rawLevels.remove(level) }
        defaults.set(rawLevels.sorted(), forKey: "learn.rawLevels")
    }
    var screenPerHour: Int {
        didSet {
            let bounded = [4, 12, 30].contains(screenPerHour) ? screenPerHour : 12
            if screenPerHour != bounded { screenPerHour = bounded }
            defaults.set(bounded, forKey: "learn.screenPerHour")
        }
    }
    var screenPermissionRequested: Bool { didSet { defaults.set(screenPermissionRequested, forKey: "learn.screenPermissionRequested") } }
    var typingPermissionRequested: Bool { didSet { defaults.set(typingPermissionRequested, forKey: "learn.typingPermissionRequested") } }
    var typingWordsHours: Int {
        didSet {
            let bounded = [0, 24, 168].contains(typingWordsHours) ? typingWordsHours : 24
            if typingWordsHours != bounded { typingWordsHours = bounded }
            defaults.set(bounded, forKey: "learn.typingWordsHours")
        }
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        rawLevels = Set((defaults.array(forKey: "learn.rawLevels") as? [Int] ?? []).filter { [3, 4].contains($0) })
        let cap = defaults.object(forKey: "learn.screenPerHour") as? Int ?? 12
        screenPerHour = [4, 12, 30].contains(cap) ? cap : 12
        screenPermissionRequested = defaults.bool(forKey: "learn.screenPermissionRequested")
        typingPermissionRequested = defaults.bool(forKey: "learn.typingPermissionRequested")
        let hours = defaults.object(forKey: "learn.typingWordsHours") as? Int ?? 24
        typingWordsHours = [0, 24, 168].contains(hours) ? hours : 24
        policies = defaults.data(forKey: "learn.levelPolicies").flatMap { try? JSONDecoder().decode([Int: ObservationPolicy].self, from: $0) } ?? [:]
    }
    func policy(_ level: Int) -> ObservationPolicy {
        var value = policies[level] ?? ObservationPolicy()
        if level == 4 {
            value.scope = .chosenApps
            if policies[level] == nil || ![7, 30, 90].contains(value.retentionDays) { value.retentionDays = 30 }
        }
        return value
    }
    func set(_ level: Int, _ policy: ObservationPolicy) {
        var policy = policy
        policy.retentionDays = min(365, max(1, policy.retentionDays))
        // Future levels cannot be enabled by imported defaults or a generic control.
        if level > 4 { policy.enabled = false }
        if level == 4 {
            policy.scope = .chosenApps
            if ![7, 30, 90].contains(policy.retentionDays) { policy.retentionDays = 30 }
        }
        if level == 3 && ![7, 30, 90].contains(policy.retentionDays) { policy.retentionDays = 90 }
        policies[level] = policy
        if let data = try? JSONEncoder().encode(policies) { defaults.set(data, forKey: "learn.levelPolicies") }
    }
    func edit(_ level: Int, _ body: (inout ObservationPolicy) -> Void) {
        var value = policy(level); body(&value); set(level, value)
    }
}
