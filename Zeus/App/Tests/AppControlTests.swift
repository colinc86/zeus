import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private struct AC2NoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor private final class AC2Surface: AppControlSurface {
    var controlAvatarFrame = CGRect(x: 100, y: 100, width: 96, height: 112)
    var controlScreens = [AppControlScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780), scale: 2, isMain: true)]
    var controlComposerFocused = false
    var controlPanelOpen = false
    var refreshes = 0
    func controlMoveAvatar(to origin: CGPoint) { controlAvatarFrame.origin = origin }
    func controlRefreshVisibility() { refreshes += 1 }
}
@MainActor private final class AC2Fixture {
    let suite = "zeus-ac2-\(UUID())"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-ac2-\(UUID())")
    let defaults: UserDefaults
    let settings: AppSettings
    let surface = AC2Surface()
    let visibility: AvatarVisibilityModel
    let model: AppControlModel
    let cards: CardStore
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: root.appendingPathComponent("Characters"), passwordStore: AC2NoCredentials())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        visibility = AvatarVisibilityModel(defaults: defaults, clock: { t })
        model = AppControlModel(settings: settings, visibility: visibility, updater: UpdaterService(), surface: surface,
            activeWindow: { nil }, idleSeconds: { 123 }, info: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "10"])
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { t })
    }
    func cleanup() { settings.stopWatchingUserFolders(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

@MainActor struct AppControlTests {
    @Test func cornersUseCurrentDisplayAndPointsUseDragClamping() throws {
        let left = AppControlScreen(frame: CGRect(x: -1200, y: -200, width: 1200, height: 1000), visibleFrame: CGRect(x: -1200, y: -180, width: 1200, height: 950), scale: 1)
        let main = AppControlScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780), scale: 2, isMain: true)
        let avatar = CGRect(x: -800, y: 100, width: 96, height: 112)
        for (placement, expected) in [(AvatarPlacement.topLeft, CGPoint(x: -1176, y: 634)), (.topRight, CGPoint(x: -120, y: 634)),
                                     (.bottomLeft, CGPoint(x: -1176, y: -156)), (.bottomRight, CGPoint(x: -120, y: -156))] {
            #expect(try AppControlPlacement.origin(for: placement, avatar: avatar, screens: [left, main], activeWindow: nil) == expected)
        }
        let proposed = CGRect(x: -2000, y: 1800, width: 96, height: 112)
        #expect(try AppControlPlacement.origin(for: .point(screen: 0, x: -800, y: 2000), avatar: avatar, screens: [left, main], activeWindow: nil)
                == PanelPlacement.clamp(proposed, to: left.visibleFrame).origin)
        #expect(throws: AppControlError.self) { try AppControlPlacement.origin(for: .point(screen: 2, x: 0, y: 0), avatar: avatar, screens: [left, main], activeWindow: nil) }
        #expect(throws: AppControlError.self) { try AppControlPlacement.origin(for: .point(screen: 0, x: .nan, y: 0), avatar: avatar, screens: [left], activeWindow: nil) }
    }
    @Test func activeWindowChoosesItsNearestScreenEdgeAndFallbackUsesMainRight() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        let screen = f.surface.controlScreens[0], avatar = f.surface.controlAvatarFrame
        #expect(try AppControlPlacement.origin(for: .nearActiveWindow, avatar: avatar, screens: [screen], activeWindow: nil) == CGPoint(x: 880, y: 334))
        let active = CGRect(x: 8, y: 100, width: 300, height: 500)
        #expect(try AppControlPlacement.origin(for: .nearActiveWindow, avatar: avatar, screens: [screen], activeWindow: active) == CGPoint(x: 24, y: 294))
        let prior = f.surface.controlAvatarFrame.origin
        let change = try f.model.move(to: .topRight)
        #expect(f.surface.controlAvatarFrame.origin == CGPoint(x: 880, y: 644))
        change.undo(); #expect(f.surface.controlAvatarFrame.origin == prior)
        f.surface.controlComposerFocused = true
        #expect(throws: AppControlError.invalidArgument("the user is typing")) { try f.model.move(to: .bottomLeft) }
        #expect(f.surface.controlAvatarFrame.origin == prior)
    }
    @Test func masterSwitchDefaultsOnPersistsAndRejectsEveryMutation() async throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        #expect(f.settings.assistantMayControlApp && f.settings.assistantMayInstallUpdates)
        f.settings.assistantMayControlApp = false; f.settings.assistantMayInstallUpdates = false
        let restored = AppSettings(defaults: f.defaults, userDirectory: nil, passwordStore: AC2NoCredentials())
        #expect(!restored.assistantMayControlApp && !restored.assistantMayInstallUpdates)
        let disabled = AppControlError.disabled(setting: "Let my assistant control Zeus")
        #expect(throws: disabled) { try f.model.setCharacter(id: "missing") }
        #expect(throws: disabled) { try f.model.setTheme(id: "missing") }
        #expect(throws: disabled) { try f.model.createCharacter(name: "Bad", json: Data()) }
        #expect(throws: disabled) { try f.model.createTheme(name: "Bad", json: Data()) }
        #expect(throws: disabled) { try f.model.move(to: .bottomRight) }
        #expect(throws: disabled) { try f.model.setSize(.large) }
        #expect(throws: disabled) { try f.model.hide(minutes: 60, untilTomorrow: false) }
        #expect(throws: disabled) { try f.model.setAppearance(.init(font: "pixel")) }
        await #expect(throws: disabled) { try await f.model.checkForUpdates() }
        await #expect(throws: disabled) { try await f.model.installUpdate(version: "1.1") }
        #expect(f.model.appControlState.version == "1.0", "Read-only state remains available")
    }
    @Test func hideMinutesRestoresAndAppearancePatchIsAtomicAndUndoIsLocal() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        let change = try f.model.hide(minutes: 17, untilTomorrow: false)
        #expect(f.visibility.hiddenUntil == Date(timeIntervalSince1970: 1_800_001_020) && f.visibility.isHidden)
        #expect(change.undoTitle == "Show now")
        change.undo(); #expect(!f.visibility.isHidden && f.surface.refreshes == 2)
        for minutes in [0, 721] { #expect(throws: AppControlError.self) { try f.model.hide(minutes: minutes, untilTomorrow: false) } }
        #expect(throws: AppControlError.self) { try f.model.hide(minutes: 1, untilTomorrow: true) }
        #expect(throws: AppControlError.self) { try f.model.hide(minutes: nil, untilTomorrow: false) }
        let old = f.settings.fontChoice, size = f.settings.avatarSize
        let look = try f.model.setAppearance(.init(ghostMode: true, ghostOpacity: 0.5, ghostDelaySeconds: 45, popupSound: true,
            popupSoundName: "glass", font: "system", panelWidth: 550, quietHours: true, quietStartHour: 0, quietEndHour: 0))
        #expect(f.settings.fadeZeusWhenIdle && f.settings.idleOpacity == 0.5 && f.settings.idleFadeDelay == 45)
        #expect(f.settings.fontChoice == .system && f.settings.popupSound == .glass && f.settings.conversationWidth == 550)
        #expect(f.model.appControlState.quietHoursActive)
        look.undo(); #expect(f.settings.fontChoice == old && f.settings.avatarSize == size && !f.settings.fadeZeusWhenIdle)
        #expect(!f.settings.popupSoundEnabled && !f.settings.quietHoursEnabled)
        #expect(throws: AppControlError.self) { try f.model.setAppearance(.init(ghostMode: true, font: "missing")) }
        #expect(!f.settings.fadeZeusWhenIdle)
        #expect(throws: AppControlError.self) { try f.model.setAppearance(.init(popupSoundName: "missing")) }
        #expect(throws: AppControlError.self) { try f.model.setAppearance(.init(quietStartHour: 24)) }
        #expect(throws: AppControlError.self) { try f.model.setAppearance(.init(panelWidth: .infinity)) }
        let resized = try f.model.setSize(.large); #expect(f.settings.avatarSize == .large)
        resized.undo(); #expect(f.settings.avatarSize == size)
    }
    @Test func importAndCreateShareValidationAndCreationUndoKeepsTheFile() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        let json = Data(##"{"id":"ac2-blob","name":"Blob","size":[4,4],"canvas":{"size":[12,20],"origin":[4,14],"anchor":[6,18]},"palette":{"k":"#000000"},"layers":{"a":{"rows":["kk"]}},"animations":{"idle":{"fps":1,"frames":[["a"]]}}}"##.utf8)
        let previous = f.settings.currentCharacterID
        let change = try f.model.createCharacter(name: "Blob", json: json)
        let file = f.root.appendingPathComponent("Characters/ac2-blob.json")
        let installed = try Data(contentsOf: file)
        #expect(f.settings.currentCharacterID == "ac2-blob" && installed == json)
        change.undo(); #expect(f.settings.currentCharacterID == previous && FileManager.default.fileExists(atPath: file.path))
        #expect(throws: AppControlError.unknownID("unknown")) { try f.model.setCharacter(id: "unknown") }
        #expect(throws: AppControlError.unknownID("unknown")) { try f.model.setTheme(id: "unknown") }
        let bad = Data(#"{"id":"bad"}"#.utf8), source = f.root.appendingPathComponent("Bad.json")
        try bad.write(to: source)
        let importer = LibraryImportModel.characters(f.settings)
        importer.importFile(at: source)
        guard case .failed(_, let lines) = importer.notice else { Issue.record("Expected invalid import"); return }
        #expect(throws: AppControlError.invalidFile(lines.joined(separator: "\n"))) { try f.model.createCharacter(name: "Bad", json: bad) }
        let example = try LibraryImportModel.themes(f.settings).exampleFile()
        let themeData = try Data(contentsOf: #require(example))
        let themeJSON = try #require(String(data: themeData, encoding: .utf8)).replacingOccurrences(of: "_example", with: "ac2-theme")
        let oldTheme = f.settings.currentThemeID
        let theme = try f.model.createTheme(name: "Theme", json: Data(themeJSON.utf8))
        #expect(f.settings.currentThemeID != oldTheme)
        let themeFile = f.root.appendingPathComponent("Themes/\(f.settings.currentThemeID).json")
        theme.undo(); #expect(f.settings.currentThemeID == oldTheme && FileManager.default.fileExists(atPath: themeFile.path))
    }
    @Test func stateIncludesDisplayRelativePositionFlagsFormatsAndNoCredentials() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        f.surface.controlScreens[0] = AppControlScreen(frame: CGRect(x: -1000, y: -200, width: 1000, height: 800),
            visibleFrame: CGRect(x: -1000, y: -200, width: 1000, height: 780), scale: 2)
        f.surface.controlAvatarFrame.origin = CGPoint(x: -900, y: -100)
        f.surface.controlPanelOpen = true
        let state = f.model.appControlState
        #expect(state.position == ["x": 100, "y": 100] && state.screen == 0)
        #expect(state.screens == [["width": 1000, "height": 800, "scale": 2]])
        #expect(state.panelOpen && !state.hidden && state.hiddenUntil == nil && state.userIdleSeconds == 123)
        #expect(state.characterID == f.settings.currentCharacterID && state.themeID == f.settings.currentThemeID && state.size == "medium")
        for path in state.formats.values { #expect(FileManager.default.fileExists(atPath: path)) }
        #expect(state.formats.count == 2)
    }
    @Test func recordedChangePersistsWithoutClosureAndRunsUndoOnceEvenIfControlIsOff() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        let previous = f.settings.avatarSize
        let recording: any AppChangeRecording = f.cards
        recording.recordAppChange(try f.model.setSize(.large))
        let notice = try #require(f.cards.notices.first)
        #expect(f.cards.cards.isEmpty && f.cards.unseenCount == 0)
        let model = ConversationModel(cards: f.cards, messaging: AgentMessagingHub())
        guard case .appChange = model.thread[0].content else { Issue.record("App change has its own content case"); return }
        f.settings.assistantMayControlApp = false
        f.cards.performNoticeAction(id: notice.id); f.cards.performNoticeAction(id: notice.id)
        #expect(f.settings.avatarSize == previous && f.cards.notices.first?.resolvedTitle == "Undone")
        let reload = CardStore(fileURL: f.root.appendingPathComponent("cards.json"))
        #expect(reload.notices == f.cards.notices && !reload.hasNoticeAction(id: notice.id))
        #expect(f.cards.clearConversation() && f.cards.notices.isEmpty)
    }
    @Test func failedRecordAndUndoKeepTheActionForPersistenceRetry() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("cards.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        f.cards.recordAppChange(try f.model.setSize(.large))
        #expect(f.cards.notices.isEmpty && f.cards.persistenceError != nil && f.settings.avatarSize == .large)
        try FileManager.default.removeItem(at: file)
        #expect(f.cards.retryPersistence() && f.cards.notices.count == 1)
        let notice = try #require(f.cards.notices.first)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        f.cards.performNoticeAction(id: notice.id)
        #expect(f.settings.avatarSize == .large && f.cards.hasNoticeAction(id: notice.id))
        try FileManager.default.removeItem(at: file)
        f.cards.performNoticeAction(id: notice.id)
        #expect(f.settings.avatarSize == .medium && !f.cards.hasNoticeAction(id: notice.id))
    }
}
