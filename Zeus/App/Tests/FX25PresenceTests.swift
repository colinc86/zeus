import Foundation
import Testing
@testable import Zeus

/// FX25: Hide Until Tomorrow ends at the start of the user's day; Zeus keeps a home per display set.
@MainActor struct FX25PresenceTests {
    private func defaults() throws -> (String, UserDefaults) {
        let name = TestDefaults.suite("zeus-fx25")
        return (name, try #require(UserDefaults(suiteName: name)))
    }
    private var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return calendar
    }

    @Test func untilTomorrowEndsAtEightUnlessQuietHoursRunLater() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let calendar = chicago
        let clock = TestClock()
        clock.now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 22, minute: 40)))
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let model = AvatarVisibilityModel(defaults: defaults, clock: { clock.now }, calendar: calendar,
                                          quietHoursEnd: { wake, cal in settings.quietHoursEnd(containing: wake, calendar: cal) })
        // Quiet hours off: 08:00 tomorrow.
        model.hide(for: .tomorrow)
        #expect(model.hiddenUntil == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8)))
        #expect(model.isHidden)
        // Quiet hours 22:00–07:00 end before 08:00: still 08:00.
        settings.quietHoursEnabled = true; settings.quietStartHour = 22; settings.quietEndHour = 7
        model.hide(for: .tomorrow)
        #expect(model.hiddenUntil == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8)))
        // Quiet hours 22:00–09:00 contain 08:00: the hide lasts until they end.
        settings.quietEndHour = 9
        model.hide(for: .tomorrow)
        #expect(model.hiddenUntil == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9)))
        // All-day quiet hours never end: fall back to 08:00 rather than hiding forever.
        settings.quietStartHour = 9; settings.quietEndHour = 9
        model.hide(for: .tomorrow)
        #expect(model.hiddenUntil == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8)))
        // Hiding in the small hours still means tomorrow's morning, not today's.
        clock.now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 1)))
        settings.quietHoursEnabled = false
        model.hide(for: .tomorrow)
        #expect(model.hiddenUntil == calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8)))
    }

    @Test func quietHoursEndIsNilOutsideQuietHoursAndWhenTheyNeverEnd() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let calendar = chicago
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let eight = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8)))
        #expect(settings.quietHoursEnd(containing: eight, calendar: calendar) == nil)
        settings.quietHoursEnabled = true; settings.quietStartHour = 22; settings.quietEndHour = 7
        #expect(settings.quietHoursEnd(containing: eight, calendar: calendar) == nil)
        settings.quietEndHour = 9
        #expect(settings.quietHoursEnd(containing: eight, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9)))
        settings.quietStartHour = 9
        #expect(settings.quietHoursEnd(containing: eight, calendar: calendar) == nil)
    }

    @Test func hiddenUntilLineReadsRelativeToToday() throws {
        let calendar = chicago
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 13, minute: 5)))
        let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 14, minute: 30)))
        let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8)))
        let farther = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 8)))
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        #expect(MenuPresentation.hiddenUntilLine(later, now: now, calendar: calendar) == "Hidden until \(time(later))")
        #expect(MenuPresentation.hiddenUntilLine(tomorrow, now: now, calendar: calendar) == "Hidden until tomorrow, \(time(tomorrow))")
        #expect(MenuPresentation.hiddenUntilLine(farther, now: now, calendar: calendar) == "Hidden until \(farther.formatted(date: .abbreviated, time: .shortened))")
    }

    @Test func homesRememberEachDisplaySetAndFallBackToTheLastOne() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let laptop = [CGRect(x: 0, y: 0, width: 1512, height: 944)]
        let docked = [CGRect(x: 0, y: 0, width: 1512, height: 944), CGRect(x: 1512, y: 0, width: 2560, height: 1415)]
        let dockedReordered = Array(docked.reversed())
        #expect(AvatarHomes.displaySetKey(docked) == AvatarHomes.displaySetKey(dockedReordered))
        #expect(AvatarHomes.displaySetKey(docked) != AvatarHomes.displaySetKey(laptop))
        var homes = AvatarHomes(defaults: defaults)
        #expect(homes.anchor(for: laptop) == nil)
        homes.record(CGPoint(x: 3800, y: 90), screens: docked)
        // Unplugged: no home for the laptop-only set yet, so the last home is offered (the shell clamps it on screen).
        #expect(homes.anchor(for: laptop) == CGPoint(x: 3800, y: 90))
        homes.record(CGPoint(x: 1300, y: 90), screens: laptop)
        // Re-docked: the docked home is back, untouched by the laptop-only clamp.
        #expect(homes.anchor(for: dockedReordered) == CGPoint(x: 3800, y: 90))
        #expect(homes.anchor(for: laptop) == CGPoint(x: 1300, y: 90))
        homes.save(to: defaults)
        let restored = AvatarHomes(defaults: defaults)
        #expect(restored == homes)
        #expect(defaults.object(forKey: AvatarHomes.lastXKey) as? Double == 1300)
        // Legacy single anchor still restores as the fallback.
        let legacyName = TestDefaults.suite("zeus-fx25-legacy")
        let legacy = try #require(UserDefaults(suiteName: legacyName)); defer { legacy.removePersistentDomain(forName: legacyName) }
        legacy.set(640.0, forKey: AvatarHomes.lastXKey); legacy.set(120.0, forKey: AvatarHomes.lastYKey)
        #expect(AvatarHomes(defaults: legacy).anchor(for: docked) == CGPoint(x: 640, y: 120))
        // Bounded: many arrangements never grow without limit.
        var many = AvatarHomes()
        for index in 0..<40 { many.record(CGPoint(x: Double(index), y: 0), screens: [CGRect(x: 0, y: 0, width: 100 + index, height: 100)]) }
        #expect(many.byDisplaySet.count <= 16)
    }
}
