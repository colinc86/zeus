import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import ZeusDesign
import ZeusProtocol
import ZeusSprites
@testable import Zeus

@MainActor
struct IdlePerformanceTests {
    @Test(arguments: CharacterLibrary.bundledOrder)
    func cachedDriverHoldsFrameCancelsClockAndRefreshesOnResume(_ id: String) throws {
        let character = try #require(CharacterLibrary.load(userDirectory: nil).character(id: id))
        let clock = TestClock()
        let driver = SpriteAnimationDriver(clock: { clock.now })
        let active = SpriteAnimationDriver.Inputs(character: character, state: .idle, reduceMotion: false, active: true)
        driver.configure(character: character, inputs: active)
        let first = try #require(driver.image)
        let assignments = driver.imageAssignments
        driver.refresh()
        #expect(driver.image === first)
        #expect(driver.imageAssignments == assignments)
        #expect(driver.scheduledInterval == SpriteRenderer.refreshInterval(character, state: .idle))
        driver.configure(character: character, inputs: .init(character: character, state: .idle, reduceMotion: false, active: false))
        #expect(driver.scheduledInterval == nil)
        clock.advance(15)
        driver.refresh()
        #expect(driver.image === first)
        #expect(driver.imageAssignments == assignments)
        driver.configure(character: character, inputs: active)
        #expect(driver.scheduledInterval == SpriteRenderer.refreshInterval(character, state: .idle))
        let expected = SpriteRenderer.signature(character, state: .idle, time: clock.now.timeIntervalSinceReferenceDate)
        let initial = SpriteRenderer.signature(character, state: .idle, time: clock.now.addingTimeInterval(-15).timeIntervalSinceReferenceDate)
        #expect(driver.imageAssignments == assignments + (expected == initial ? 0 : 1))
        driver.pause()
    }

    @Test func driverReconfiguresStateMotionAndCharacterWhileInactive() throws {
        let library = CharacterLibrary.load(userDirectory: nil)
        let zeus = try #require(library.character(id: "zeus"))
        let other = try #require(library.characters.first { $0.id != zeus.id })
        let driver = SpriteAnimationDriver()
        driver.configure(character: zeus, inputs: .init(character: zeus, state: .idle, reduceMotion: false, active: true))
        let before = driver.image
        driver.configure(character: other, inputs: .init(character: other, state: .working, reduceMotion: true, active: false))
        #expect(driver.image === before)
        #expect(driver.scheduledInterval == nil)
        driver.configure(character: other, inputs: .init(character: other, state: .working, reduceMotion: true, active: true))
        #expect(driver.image !== before)
        #expect(driver.scheduledInterval == SpriteRenderer.refreshInterval(other, state: .working, options: .init(reduceMotion: true)))
        driver.pause()
    }

    @Test func nativeSpriteUpdatesOnlyItsNearestNeighborLayerAndDetachingStopsTheClock() throws {
        let character = try #require(CharacterLibrary.load(userDirectory: nil).character(id: "zeus"))
        let clock = TestClock()
        let driver = SpriteAnimationDriver(clock: { clock.now })
        let view = PixelSpriteLayerView(driver: driver)
        driver.configure(character: character, inputs: .init(character: character, state: .idle, reduceMotion: false, active: true))
        let first = try #require((view.layer?.contents as AnyObject?))
        let matchesDriver = first === driver.image
        #expect(matchesDriver)
        #expect(view.layer?.magnificationFilter == .nearest && view.layer?.minificationFilter == .nearest)
        driver.refresh()
        let retainedContents = (view.layer?.contents as AnyObject?) === first
        #expect(retainedContents)
        clock.advance(0.5); driver.refresh()
        let updatedContents = (view.layer?.contents as AnyObject?) === driver.image
        #expect(updatedContents)
        view.viewDidMoveToWindow()
        #expect(driver.scheduledInterval == nil)
        let count = driver.imageAssignments
        clock.advance(1); driver.refresh()
        #expect(driver.imageAssignments == count)
    }

    @Test func conversationHostUnmountsWithoutLosingDraftOrThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-conversation-host-\(UUID())")
        let name = "zeus-conversation-host-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        cards.add(Card(kind: .message, body: "A retained message", status: .dismissed))
        let shell = ShellController(defaults: defaults, cards: cards, settings: AppSettings(defaults: defaults, userDirectory: nil))
        shell.conversation.draft = "An unfinished reply"
        let model = shell.conversation
        let entries = model.thread.map(\.id)
        #expect(!shell.isConversationMounted)
        shell.mountConversation()
        #expect(shell.isConversationMounted)
        shell.unmountConversation()
        #expect(!shell.isConversationMounted)
        shell.mountConversation()
        #expect(shell.isConversationMounted)
        #expect(shell.conversation === model)
        #expect(model.draft == "An unfinished reply")
        #expect(model.thread.map(\.id) == entries)
        shell.unmountConversation()
    }

    @Test func idleTicksDoNotPublishPresentationActivityOrVisibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-idle-\(UUID())")
        let name = "zeus-idle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let clock = TestClock()
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let status = AvatarStatusModel(cards: cards, clock: { clock.now })
        let visibility = AvatarVisibilityModel(defaults: defaults, clock: { clock.now })
        let changes = Mutex(0)
        withObservationTracking {
            _ = status.presentation; _ = status.activity; _ = visibility.isHidden
        } onChange: { changes.withLock { $0 += 1 } }
        for _ in 0..<100 { clock.advance(0.25); status.tick(); visibility.tick() }
        #expect(changes.withLock { $0 } == 0)
        #expect(status.nextDeadline == nil)
        status.setOverride(.working, detail: "Building", progress: nil, ttl: 5)
        #expect(status.activity?.state == .working)
        let expiryChanges = Mutex(0)
        withObservationTracking { _ = status.presentation; _ = status.activity } onChange: { expiryChanges.withLock { $0 += 1 } }
        clock.advance(4.999); status.tick()
        #expect(expiryChanges.withLock { $0 } == 0)
        clock.advance(0.001); status.tick()
        #expect(expiryChanges.withLock { $0 } == 1)
        #expect(status.state == .idle && status.activity == nil)
        #expect(status.nextDeadline == nil)
    }

    @Test func deadlineSelectionAndTimedHideHaveNoIdleWake() throws {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(LifecycleDeadline.earliest(after: now, candidates: [nil, now, now.addingTimeInterval(-1)]) == nil)
        #expect(LifecycleDeadline.earliest(after: now, candidates: [now.addingTimeInterval(30), now.addingTimeInterval(3)]) == now.addingTimeInterval(3))
        let name = "zeus-deadline-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock()
        let visibility = AvatarVisibilityModel(defaults: defaults, clock: { clock.now })
        visibility.hide(for: .hour)
        let changes = Mutex(0)
        withObservationTracking { _ = visibility.isHidden } onChange: { changes.withLock { $0 += 1 } }
        clock.advance(3599); visibility.tick()
        #expect(changes.withLock { $0 } == 0)
        clock.advance(1); visibility.tick()
        #expect(changes.withLock { $0 } == 1)
        #expect(!visibility.isHidden && visibility.hiddenUntil == nil)
    }

    @Test func everySurfacePausesDuringSuspensionAndDoesNotPublishUnchangedActivity() {
        let activity = SurfaceActivity()
        activity.update(suspended: false, avatar: true, conversation: true, peek: true, settings: true)
        #expect(activity.avatar && activity.conversation && activity.peek && activity.settings)
        let changes = Mutex(0)
        withObservationTracking { _ = activity.avatar; _ = activity.conversation; _ = activity.peek; _ = activity.settings } onChange: { changes.withLock { $0 += 1 } }
        activity.update(suspended: false, avatar: true, conversation: true, peek: true, settings: true)
        #expect(changes.withLock { $0 } == 0)
        activity.update(suspended: true, avatar: true, conversation: true, peek: true, settings: true)
        #expect(changes.withLock { $0 } == 1)
        #expect(!activity.avatar && !activity.conversation && !activity.peek && !activity.settings)
        activity.update(suspended: false, avatar: true, conversation: false, peek: false, settings: false)
        #expect(activity.avatar && !activity.conversation && !activity.peek && !activity.settings)
    }

    @Test func quietDeadlinesFollowLocalCalendarAndDisabledOrAllDayHasNoClock() throws {
        let name = "zeus-quiet-deadline-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1)))
        #expect(settings.nextQuietBoundary(after: date, calendar: calendar) == nil)
        settings.quietHoursEnabled = true
        settings.quietStartHour = 22; settings.quietEndHour = 7
        let end = try #require(settings.nextQuietBoundary(after: date, calendar: calendar))
        #expect(calendar.component(.hour, from: end) == 7)
        #expect(end.timeIntervalSince(date) == 5 * 3600)
        #expect(settings.isQuiet(at: end.addingTimeInterval(-1), calendar: calendar))
        #expect(!settings.isQuiet(at: end, calendar: calendar))
        #expect(calendar.component(.hour, from: try #require(settings.nextQuietBoundary(after: end, calendar: calendar))) == 22)
        settings.quietStartHour = 7
        #expect(settings.nextQuietBoundary(after: date, calendar: calendar) == nil)
    }

    @Test func completedRevealAndUnchangedCharacterCountStopPublishing() {
        let clock = TestClock()
        let reveal = TypewriterModel(clock: { clock.now })
        reveal.configure(text: "A small message", animate: true)
        let changes = Mutex(0)
        withObservationTracking { _ = reveal.visibleCount } onChange: { changes.withLock { $0 += 1 } }
        for _ in 0..<10 { reveal.tick() }
        #expect(changes.withLock { $0 } == 0)
        clock.advance(3); reveal.tick()
        #expect(!reveal.isRevealing)
        let completed = Mutex(0)
        withObservationTracking { _ = reveal.visibleCount } onChange: { completed.withLock { $0 += 1 } }
        clock.advance(10); reveal.tick()
        #expect(completed.withLock { $0 } == 0)
    }

    @Test func highPriorityPeekHasNoDeadlineAfterItsLastCharacter() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-peek-idle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let peek = PeekModel(store: store, clock: { clock.now })
        let card = Card(kind: .message, body: "Hello", priority: .high)
        store.add(card)
        #expect(peek.receive(card, suppression: .init(), reduceMotion: false, typewriter: true))
        #expect(peek.nextDeadline != nil)
        clock.advance(3); peek.tick(suppression: .init())
        #expect(peek.isVisible && !peek.isTyping)
        #expect(peek.nextDeadline == nil)
    }
}
