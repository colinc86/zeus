import Carbon
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct EverydayPolishTests {
    private func defaults() throws -> (String, UserDefaults) {
        let name = "zeus-polish-tests-\(UUID())"
        return (name, try #require(UserDefaults(suiteName: name)))
    }

    @Test func hourHidePersistsExpiresAtBoundaryAndExplicitShowCancels() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock()
        let model = AvatarVisibilityModel(defaults: defaults, clock: { clock.now })
        model.hide(for: .hour)
        #expect(model.hiddenUntil == clock.now.addingTimeInterval(3600))
        #expect(model.isHidden)
        let restored = AvatarVisibilityModel(defaults: defaults, clock: { clock.now })
        #expect(restored.isHidden)
        clock.advance(3599); restored.tick()
        #expect(restored.isHidden)
        clock.advance(1); restored.tick()
        #expect(!restored.isHidden)
        #expect(restored.hiddenUntil == nil)
        restored.hide(for: .hour); restored.show()
        #expect(!restored.isHidden)
        #expect(defaults.object(forKey: "avatar.hiddenUntil") == nil)
    }

    @Test func untilTomorrowUsesLocalWakeHourAcrossDaylightSavingChanges() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let clock = TestClock()
        clock.now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        let spring = AvatarVisibilityModel(defaults: defaults, clock: { clock.now }, calendar: calendar)
        spring.hide(for: .tomorrow)
        let springEnd = try #require(spring.hiddenUntil)
        #expect(springEnd.timeIntervalSince(clock.now) == TimeInterval(31 * 3600)) // 08:00 next day across the 23-hour day
        clock.now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0)))
        let autumn = AvatarVisibilityModel(defaults: defaults, clock: { clock.now }, calendar: calendar)
        autumn.hide(for: .tomorrow)
        let autumnEnd = try #require(autumn.hiddenUntil)
        #expect(autumnEnd.timeIntervalSince(clock.now) == TimeInterval(33 * 3600)) // 08:00 next day across the 25-hour day
        let until = try #require(autumn.hiddenUntil)
        #expect(calendar.component(.hour, from: until) == 8)
        #expect(calendar.component(.day, from: until) == 2)
    }

    @Test func newTomorrowHideUsesChangedTimezoneWithoutReinterpretingExistingDeadline() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock()
        clock.now = Date(timeIntervalSince1970: 1791892800)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let model = AvatarVisibilityModel(defaults: defaults, clock: { clock.now }, calendarProvider: { local })
        model.hide(for: .tomorrow)
        let original = model.hiddenUntil
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        model.tick()
        #expect(model.hiddenUntil == original)
        model.hide(for: .tomorrow)
        #expect(model.hiddenUntil == local.date(byAdding: .day, value: 1, to: local.startOfDay(for: clock.now)).flatMap { local.date(bySettingHour: 8, minute: 0, second: 0, of: $0) })
        #expect(model.hiddenUntil != original)
    }

    @Test func indefiniteHideAndExpiredRestartStateAreHandledSeparately() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock()
        let model = AvatarVisibilityModel(defaults: defaults, clock: { clock.now })
        model.hide()
        clock.advance(90000); model.tick()
        #expect(model.isHidden)
        #expect(model.hiddenUntil == nil)
        #expect(AvatarVisibilityModel(defaults: defaults, clock: { clock.now }).manuallyHidden)
        model.hide(for: .hour)
        #expect(!model.manuallyHidden)
        clock.advance(3600)
        #expect(!AvatarVisibilityModel(defaults: defaults, clock: { clock.now }).isHidden)
    }

    @Test func hotkeyPersistsAndInvalidStoredShortcutFallsBackSafely() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.talkHotKey.displayName == "⌥⌘Z")
        #expect(settings.talkHotKey.keyCode == UInt32(kVK_ANSI_Z))
        settings.talkHotKey = TalkHotKey(key: "K", command: false, option: false, control: true, shift: true)
        settings.soundEnabled = true; settings.typewriterEnabled = false
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(restored.talkHotKey == settings.talkHotKey)
        #expect(restored.soundEnabled)
        #expect(!restored.typewriterEnabled)
        defaults.set(Data("invalid json".utf8), forKey: "general.talkHotKey")
        #expect(AppSettings(defaults: defaults, userDirectory: nil).talkHotKey == TalkHotKey())
        settings.talkHotKey = TalkHotKey(key: "Z", command: false, option: false, control: false, shift: false, enabled: false)
        #expect(!AppSettings(defaults: defaults, userDirectory: nil).talkHotKey.enabled)
    }

    @Test func hotkeyValidationRejectsUnmodifiedAndUnknownKeys() {
        #expect(!TalkHotKey(key: "Z", command: false, option: false).isValid)
        #expect(!TalkHotKey(keyCode: UInt32.max).isValid)
        #expect(TalkHotKey.letters.allSatisfy { TalkHotKey(key: $0).isValid })
    }

    @Test func talkShortcutClosesOnlyAnAlreadyKeyConversation() {
        #expect(!ConversationLayout.hotKeyCloses(isVisible: false, isKey: false))
        #expect(!ConversationLayout.hotKeyCloses(isVisible: true, isKey: false))
        #expect(ConversationLayout.hotKeyCloses(isVisible: true, isKey: true))
    }

    @Test func welcomeIsInstalledOnlyOnceAndDoesNotCreateAnAgentResponse() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-welcome-tests-\(UUID())").appendingPathComponent("cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let cards = CardStore(fileURL: url)
        var replies = 0
        cards.responseHandler = { _, _ in replies += 1 }
        #expect(WelcomeCard.installIfNeeded(cards: cards, settings: settings))
        #expect(cards.openCards.first?.id == WelcomeCard.id)
        #expect(cards.openCards.first?.options.isEmpty == true)
        cards.dismiss(id: WelcomeCard.id)
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(!WelcomeCard.installIfNeeded(cards: cards, settings: restored))
        #expect(cards.cards.count == 1)
        #expect(cards.history.count == 1)
        #expect(replies == 0)
        #expect(!settings.soundEnabled)
    }

    @Test func typewriterUsesGraphemeClustersAndCompletesWithoutMotion() {
        let clock = TestClock()
        let reveal = TypewriterModel(clock: { clock.now })
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 80)
        reveal.configure(text: text, animate: true)
        #expect(reveal.visibleCount == 0)
        clock.advance(1); reveal.tick()
        #expect(reveal.visibleCount == 40)
        reveal.configure(text: text, animate: false)
        #expect(reveal.visibleCount == 80)
        #expect(!reveal.isRevealing)
    }

    @Test func hiddenMessageStartsWhenShownAndClickFinishesImmediately() {
        let clock = TestClock()
        let reveal = TypewriterModel(clock: { clock.now })
        let text = String(repeating: "x", count: 100)
        reveal.configure(text: text, animate: false, active: false)
        clock.advance(100)
        reveal.configure(text: text, animate: true)
        #expect(reveal.visibleCount == 0)
        clock.advance(0.5); reveal.tick()
        #expect(reveal.visibleCount == 20)
        reveal.finish()
        #expect(reveal.visibleCount == 100)
        #expect(!reveal.tick())
    }
}
