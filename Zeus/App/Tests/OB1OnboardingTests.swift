import Foundation
import AppKit
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private struct OB1TestCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor struct OB1OnboardingTests {
    @Test func freshManagedLaunchShowsExactlyTheD19WelcomeAndKeepsItsModeOnRelaunch() throws {
        let suite = "zeus-ob1-welcome-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: OB1TestCredentials())
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        #expect(WelcomeCard.installForLaunch(cards: cards, settings: settings, isHidden: false))
        #expect(cards.cards.map(\.id) == [WelcomeCard.id] && cards.cards[0].body == WelcomeCard.body)
        #expect(settings.hasShownWelcome && settings.managedSession?.enabled == true && settings.managedSession?.folder == "")
        let restored = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: OB1TestCredentials())
        #expect(restored.managedSession?.enabled == true)
        #expect(!WelcomeCard.installForLaunch(cards: cards, settings: restored, isHidden: false) && cards.cards.count == 1)
    }
    @Test func failedHistorySaveDoesNotConsumeTheWelcome() throws {
        let suite = "zeus-ob1-save-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory"); try Data().write(to: blocker)
        let cards = CardStore(fileURL: blocker.appendingPathComponent("cards.json"))
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: OB1TestCredentials())
        #expect(!WelcomeCard.installForLaunch(cards: cards, settings: settings, isHidden: false))
        #expect(!settings.hasShownWelcome && cards.cards.isEmpty && cards.persistenceError != nil)
    }
}

extension OB1OnboardingTests {
    @Test func offStripDoesNotClaimIdleAndKeepsQuestionPrecedence() {
        let off = StatusStripState.Managed(enabled: false, isOff: true, status: .off)
        let quiet = StatusStripState.Status(avatar: .init(state: .idle))
        #expect(StatusStripState.make(cards: .init(values: []), status: quiet, managed: off, activity: nil).sentence == "Your assistant is off")
        let question = Card(id: "q_ob1", kind: .question, body: "Choose")
        #expect(StatusStripState.make(cards: .init(values: [question], seen: [question.id]), status: quiet, managed: off, activity: nil).sentence == "Waiting for your answer")
        let connected = StatusStripState.Managed(enabled: false, isOff: false, status: .off, hasTerminal: true)
        #expect(StatusStripState.make(cards: .init(values: []), status: quiet, managed: connected, activity: nil).sentence == "Idle")
    }
}

extension OB1OnboardingTests {
    @Test func stoppedManagedAssistantIsOffWithoutMislabelingConnectedOrRetainedOwnSessions() throws {
        let suite = "zeus-ob1-off-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: OB1TestCredentials())
        settings.managedLaunchedConfig = settings.managedSession
        let controller = TruthManagedController(); controller.managedStatus = .off
        let model = ManagedAssistantModel(settings: settings, controller: { controller })
        #expect(model.assistantIsOff(connectedSessionCount: 0))
        model.chooseManaged(false)
        #expect(model.assistantIsOff(connectedSessionCount: 0))
        #expect(!model.assistantIsOff(connectedSessionCount: 1))
        controller.managedStatus = .running(.idle); controller.managedAttachCommand = "fixture attach"
        model.refreshRetainedSession()
        controller.managedStatus = .off
        #expect(model.retainedSession != nil && !model.assistantIsOff(connectedSessionCount: 0))
    }
}

@MainActor private final class OB1Sounds: PopupSoundPlaying {
    var count = 0
    func play(_ sound: PopupSound) { count += 1 }
}
extension OB1OnboardingTests {
    @Test func freshShellStartupShowsOnlyTheQuietWelcome() throws {
        _ = NSApplication.shared
        let suite = "zeus-ob1-shell-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: OB1TestCredentials())
        // This regression exercises onboarding, without competing for the human's real global shortcut.
        settings.talkHotKey.enabled = false
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), sounds = OB1Sounds()
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings, popupSound: sounds)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            shell.stop()
            for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) {
                window.orderOut(nil); window.contentView = nil; window.close()
            }
        }
        shell.start()
        #expect(cards.cards.map(\.id) == [WelcomeCard.id] && cards.unseenCount == 0)
        #expect(shell.status.state == .idle && !shell.peek.isVisible && sounds.count == 0)
        #expect(shell.cardPanelState.isVisible && shell.isConversationMounted)
    }
}
