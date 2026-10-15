import Foundation
import Observation

/// An app whose time is recorded as private: a duration with no name (CONTRACT §13).
struct ExcludedApp: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var bundleIDs: [String]
    var id: String { bundleIDs.first ?? name }

    func matches(bundleID: String?, name other: String?) -> Bool {
        if let bundleID, bundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) { return true }
        return other.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false
    }

    /// Password managers, Keychain Access, Passwords and System Settings.
    static let defaults: [ExcludedApp] = [
        .init(name: "1Password", bundleIDs: ["com.1password.1password", "com.agilebits.onepassword7"]),
        .init(name: "Bitwarden", bundleIDs: ["com.bitwarden.desktop"]),
        .init(name: "KeePassXC", bundleIDs: ["org.keepassxc.keepassxc"]),
        .init(name: "Strongbox", bundleIDs: ["com.markmcguill.strongbox.mac", "com.markmcguill.strongbox"]),
        .init(name: "Enpass", bundleIDs: ["in.sinew.Enpass-Desktop"]),
        .init(name: "Dashlane", bundleIDs: ["com.dashlane.Dashlane", "com.dashlane.dashlanephonefinal"]),
        .init(name: "Keychain Access", bundleIDs: ["com.apple.keychainaccess"]),
        .init(name: "Passwords", bundleIDs: ["com.apple.Passwords"]),
        .init(name: "System Settings", bundleIDs: ["com.apple.systempreferences"]),
    ]
}

/// Settings › Privacy's choices, in the injected defaults. Off unless the user turns it on.
@MainActor
@Observable
final class LearnSettings {
    static let retentionChoices = [7, 14, 30, 60, 90]
    @ObservationIgnored private let defaults: UserDefaults

    /// App-side per-level scope, shared with the L1 recorder; the private list always wins.
    @ObservationIgnored var permitsApp: ((String?, String?) -> Bool)?

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "learn.enabled") } }
    /// The one-time sheet was answered.
    var introShown: Bool { didSet { defaults.set(introShown, forKey: "learn.introShown") } }
    var excludedApps: [ExcludedApp] {
        didSet { if let data = try? JSONEncoder().encode(excludedApps) { defaults.set(data, forKey: "learn.excludedApps") } }
    }
    var momentKinds: Set<MomentKind> { didSet { defaults.set(momentKinds.map(\.rawValue).sorted(), forKey: "learn.moments") } }
    /// Days of raw events to keep, 7–90.
    var retentionDays: Int {
        didSet {
            let clamped = Self.clampRetention(retentionDays)
            if clamped != retentionDays { retentionDays = clamped; return }
            defaults.set(retentionDays, forKey: "learn.retentionDays")
        }
    }
    /// "Pause for today": nothing is recorded before this time.
    var pausedUntil: Date? {
        didSet {
            if let pausedUntil { defaults.set(pausedUntil, forKey: "learn.pausedUntil") } else { defaults.removeObject(forKey: "learn.pausedUntil") }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "learn.enabled")
        introShown = defaults.bool(forKey: "learn.introShown")
        excludedApps = defaults.data(forKey: "learn.excludedApps").flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) }
            ?? ExcludedApp.defaults
        momentKinds = (defaults.stringArray(forKey: "learn.moments")).map { Set($0.compactMap(MomentKind.init(rawValue:))) }
            ?? Set(MomentKind.allCases)
        retentionDays = Self.clampRetention(defaults.object(forKey: "learn.retentionDays") as? Int ?? 90)
        pausedUntil = defaults.object(forKey: "learn.pausedUntil") as? Date
    }

    func isPaused(at date: Date) -> Bool { pausedUntil.map { date < $0 } ?? false }
    func isExcluded(bundleID: String?, name: String?) -> Bool {
        excludedApps.contains { $0.matches(bundleID: bundleID, name: name) } || (permitsApp.map { !$0(bundleID, name) } ?? false)
    }
    static func clampRetention(_ days: Int) -> Int { min(90, max(7, days)) }
}
