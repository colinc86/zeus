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

@MainActor struct AppControlModelTests {
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
        let other = AppControlScreen(frame: CGRect(x: -1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: -1000, y: 0, width: 1000, height: 780), scale: 1)
        let otherAvatar = CGRect(x: -800, y: 100, width: 96, height: 112)
        #expect(try AppControlPlacement.origin(for: .nearActiveWindow, avatar: otherAvatar, screens: [other, screen], activeWindow: nil)
                == CGPoint(x: 880, y: 334), "Unknown active window uses the main display, not the avatar's display")
        let active = CGRect(x: 8, y: 100, width: 300, height: 500)
        #expect(try AppControlPlacement.origin(for: .nearActiveWindow, avatar: avatar, screens: [screen], activeWindow: active) == CGPoint(x: 24, y: 294))
        let prior = f.surface.controlAvatarFrame.origin
        let change = try f.model.move(to: .topRight)
        #expect(f.surface.controlAvatarFrame.origin == CGPoint(x: 880, y: 644))
        change.undo(); #expect(f.surface.controlAvatarFrame.origin == prior)
        f.surface.controlComposerFocused = true
        #expect(throws: AppControlError.invalidArgument("the user is typing")) { try f.model.move(to: .bottomLeft) }
        #expect(f.surface.controlAvatarFrame.origin == prior)
        #expect(throws: AppControlError.self) { try AppControlPlacement.origin(for: .topRight, avatar: avatar, screens: [], activeWindow: nil) }
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
        #expect(throws: disabled) { try f.model.setSize("large") }
        #expect(throws: disabled) { try f.model.hide(minutes: 60, untilTomorrow: false) }
        #expect(throws: disabled) { try f.model.setAppearance(.init(font: "pixel")) }
        await #expect(throws: disabled) { try await f.model.checkForUpdates() }
        await #expect(throws: disabled) { try await f.model.installUpdate(version: "1.1") }
        #expect(f.model.appControlState.version == "1.0", "Read-only state remains available")
        f.settings.assistantMayControlApp = true
        await #expect(throws: AppControlError.disabled(setting: "Let my assistant install updates")) { try await f.model.installUpdate(version: "1.1") }
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
        let fontOnly = try f.model.setAppearance(.init(font: "system"))
        f.settings.quietHoursEnabled = true
        fontOnly.undo(); #expect(f.settings.quietHoursEnabled, "Undo doesn't replace settings the change didn't touch")
        #expect(throws: AppControlError.invalidArgument("Unknown size: huge.")) { try f.model.setSize("huge") }
        let resized = try f.model.setSize("large"); #expect(f.settings.avatarSize == .large)
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
        let bundle = try #require(Bundle.main.resourceURL)
        for path in state.formats.values {
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(path.hasPrefix(bundle.path), "Release tools can read the bundled formats without a source checkout")
        }
        #expect(state.formats.count == 2)
    }
    @Test func recordedChangePersistsWithoutClosureAndRunsUndoOnceEvenIfControlIsOff() throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        let previous = f.settings.avatarSize
        let recording: any AppChangeRecording = f.cards
        recording.recordAppChange(try f.model.setSize("large"))
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
        f.cards.recordAppChange(try f.model.setSize("large"))
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

    @Test func quietLineUndoAndSettingsSwitchesRenderInNativeOffscreenWindows() async throws {
        let f = try AC2Fixture(); defer { f.cleanup() }
        f.cards.recordAppChange(try f.model.setCharacter(id: f.settings.availableCharacters.first(where: { $0.id != f.settings.currentCharacterID })?.id ?? "zeus"))
        let notice = try #require(f.cards.notices.first)
        let panel = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        func render<V: View>(_ view: V, name: String, size: CGSize) async throws -> NSHostingView<AnyView> {
            let host = NSHostingView(rootView: AnyView(view.environment(\.accessibilityEnabled, true)
                .environment(\.zeusFontChoice, .system).environment(\.zeusTheme, f.settings.currentTheme)
                .background(Color(nsColor: .windowBackgroundColor))))
            host.sizingOptions = []
            panel.contentView = host; panel.setContentSize(size); panel.orderFront(nil)
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            if ProcessInfo.processInfo.environment["ZEUS_AC2_RENDER"] == "1" {
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                var repo = URL(fileURLWithPath: #filePath)
                for _ in 0..<4 { repo.deleteLastPathComponent() }
                let out = repo.appendingPathComponent("build/ac2-renders")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try data.write(to: out.appendingPathComponent(name + ".png"))
            }
            return host
        }
        let host = try await render(ConversationNoticeLine(notice: notice, maxWidth: 360,
            hasAction: f.cards.hasNoticeAction(id: notice.id), perform: { f.cards.performNoticeAction(id: notice.id) }).padding(20),
            name: "undo", size: CGSize(width: 400, height: 100))
        func nodes(_ object: Any) -> [NSObject] {
            var visited: Set<ObjectIdentifier> = []
            func collect(_ object: Any) -> [NSObject] {
                guard let node = object as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                let children = ((node as AnyObject).accessibilityChildren?() ?? nil) ?? []
                let legacy = node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXChildren")?.takeUnretainedValue() as? [Any] ?? []
                let contents = node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXContents")?.takeUnretainedValue() as? [Any] ?? []
                return [node] + (children + legacy + contents + ((node as? NSView)?.subviews ?? [])).flatMap(collect)
            }
            return collect(object)
        }
        func label(_ node: NSObject) -> String? {
            node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXDescription")?.takeUnretainedValue() as? String
                ?? node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXTitle")?.takeUnretainedValue() as? String
                ?? ((node as AnyObject).accessibilityLabel?() ?? nil)
        }
        let undo = try #require(nodes(host).first { (($0 as AnyObject).accessibilityLabel?() ?? nil) == "Undo" })
        #expect((undo as AnyObject).accessibilityPerformPress?() == true)
        #expect(f.cards.notices.first?.resolvedTitle == "Undone")
        _ = try await render(ConversationNoticeLine(notice: try #require(f.cards.notices.first), maxWidth: 360, hasAction: false, perform: {}).padding(20),
                             name: "undone", size: CGSize(width: 400, height: 100))
        f.cards.recordAppChange(try f.model.hide(minutes: 60, untilTomorrow: false))
        _ = try await render(ConversationNoticeLine(notice: try #require(f.cards.notices.last), maxWidth: 360, hasAction: true, perform: {}).padding(20),
                             name: "show-now", size: CGSize(width: 400, height: 100))
        let hub = AgentMessagingHub(), navigation = SettingsNavigation()
        let settingsView = SettingsView(settings: f.settings, managed: ManagedAssistantModel(settings: f.settings, controller: { nil }),
            cards: f.cards, status: AvatarStatusModel(cards: f.cards), messaging: hub, preview: hub,
            testMessage: ComposeModel(cards: f.cards, messaging: hub), injectDemo: { _ in }, resetPosition: {},
            navigation: navigation, login: LoginItemModel(), hotKey: GlobalHotKey(), activity: SurfaceActivity())
        _ = try await render(settingsView, name: "settings-enabled", size: SettingsWindowSize.minimum)
        // SwiftUI's offscreen native scroll adapter omits its virtual accessibility children.
        // Inspect the same General controls without that adapter, as LiveManagedSettingsTests does.
        let general = GeneralSettingsView(settings: f.settings, login: LoginItemModel(), hotKey: GlobalHotKey(), cards: f.cards)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle())
            .textFieldStyle(ZeusTextFieldStyle()).settingsBody().padding(24)
        let generalHost = try await render(general, name: "general-accessibility", size: CGSize(width: 572, height: 1400))
        let labels = nodes(generalHost).compactMap(label)
        #expect(labels.contains("Let my assistant control Zeus") && labels.contains("Let my assistant install updates"))
        f.settings.assistantMayControlApp = false
        _ = try await render(settingsView, name: "settings-disabled", size: SettingsWindowSize.minimum)
        let disabledHost = try await render(general, name: "general-disabled-accessibility", size: CGSize(width: 572, height: 1400))
        let installs = nodes(disabledHost).filter { label($0) == "Let my assistant install updates" }
        #expect(!installs.isEmpty)
        #expect(installs.contains { node in
            let enabled = node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnabled")?.takeUnretainedValue() as? NSNumber
            return enabled?.boolValue == false || (node as AnyObject).isAccessibilityEnabled?() == false
        })
    }
}
