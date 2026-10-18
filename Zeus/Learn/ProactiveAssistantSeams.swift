import Foundation
import Observation

/// Local clock time; no activity content is collected by either schedule.
enum MorningBriefSchedule: String, Codable, CaseIterable, Sendable { case firstActivity, fixedTime }

/// Separate from learning consent. The default is used only while a managed assistant is enabled.
@MainActor @Observable
final class MorningBriefSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var hasEnabledPreference: Bool
    var enabled: Bool { didSet { hasEnabledPreference = true; defaults.set(enabled, forKey: "proactive.morningBrief.enabled") } }
    var schedule: MorningBriefSchedule { didSet { defaults.set(schedule.rawValue, forKey: "proactive.morningBrief.schedule") } }
    var hour: Int {
        didSet {
            let value = min(23, max(0, hour))
            if hour != value { hour = value }
            defaults.set(hour, forKey: "proactive.morningBrief.hour")
        }
    }
    var minute: Int {
        didSet {
            let value = min(59, max(0, minute))
            if minute != value { minute = value }
            defaults.set(minute, forKey: "proactive.morningBrief.minute")
        }
    }

    func effectiveEnabled(managed: Bool) -> Bool { hasEnabledPreference ? enabled : managed }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasEnabledPreference = defaults.object(forKey: "proactive.morningBrief.enabled") != nil
        enabled = defaults.object(forKey: "proactive.morningBrief.enabled") as? Bool ?? true
        schedule = MorningBriefSchedule(rawValue: defaults.string(forKey: "proactive.morningBrief.schedule") ?? "") ?? .firstActivity
        hour = min(23, max(0, defaults.object(forKey: "proactive.morningBrief.hour") as? Int ?? 8))
        minute = min(59, max(0, defaults.object(forKey: "proactive.morningBrief.minute") as? Int ?? 0))
    }
}

/// Optional app integration. Settings and presence are independent of learning capture.
@MainActor protocol ProactiveAssistantControlling: AnyObject {
    /// A timestamp-only user activity edge, never wake alone, an app name, or typed content.
    func noteProactiveActivity(at date: Date)
    func proactiveSettingsDidChange()
    /// Releases only a daily-budget hold. No rating change, alert replay, or queue-wide release.
    func showBudgetHeldCard(id: String) throws
}
