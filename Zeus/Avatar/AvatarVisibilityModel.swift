import Foundation
import Observation

/// Timed hiding survives restarts and never changes cards or delivery state.
@MainActor
@Observable
final class AvatarVisibilityModel {
    enum Duration { case hour, tomorrow, minutes(Int) }
    private(set) var hiddenUntil: Date?
    private(set) var manuallyHidden: Bool
    @ObservationIgnored private(set) var now: Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init, calendar: Calendar? = nil, calendarProvider: @escaping () -> Calendar = { .current }) {
        self.defaults = defaults
        self.clock = clock
        // Resolve the local calendar when the action is chosen; fixed test calendars stay fixed.
        self.calendar = calendar.map { fixed in { fixed } } ?? calendarProvider
        now = clock()
        manuallyHidden = defaults.bool(forKey: "avatar.manuallyHidden")
        if let timestamp = defaults.object(forKey: "avatar.hiddenUntil") as? Double, timestamp.isFinite {
            hiddenUntil = Date(timeIntervalSince1970: timestamp)
        }
        tick()
    }

    var isHidden: Bool { manuallyHidden || (hiddenUntil.map { now < $0 } ?? false) }

    func hide(for duration: Duration) {
        now = clock()
        manuallyHidden = false
        switch duration {
        case .hour: hiddenUntil = now.addingTimeInterval(3600)
        case .minutes(let minutes): hiddenUntil = now.addingTimeInterval(TimeInterval(min(720, max(1, minutes))) * 60)
        case .tomorrow:
            let local = calendar()
            hiddenUntil = local.date(byAdding: .day, value: 1, to: local.startOfDay(for: now))
        }
        save()
    }
    func hide() { manuallyHidden = true; hiddenUntil = nil; save() }
    func show() { manuallyHidden = false; hiddenUntil = nil; now = clock(); save() }
    func tick() {
        now = clock()
        if let hiddenUntil, hiddenUntil <= now { self.hiddenUntil = nil; save() }
    }
    private func save() {
        defaults.set(manuallyHidden, forKey: "avatar.manuallyHidden")
        defaults.set(hiddenUntil?.timeIntervalSince1970, forKey: "avatar.hiddenUntil")
    }
}
