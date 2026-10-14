import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor @Suite(.serialized) struct A12ResizeTests {
    @Test func resetThroughTheShellKeepsAnUnsentDraft() throws {
        let suite = "zeus-a12-shell-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: A12ResizeNoCredentials())
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        defer { shell.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        shell.conversation.draft = "Keep this unfinished message."
        settings.conversationWidth = 640
        shell.resetConversationWidth()
        #expect(settings.conversationWidth == Double(ConversationWidth.minimum))
        #expect(shell.conversation.draft == "Keep this unfinished message.")
    }

    @Test func nativeResizeFocusRingFollowsEveryLiveThemeWithoutReplacingTheEditor() async throws {
        let suite = "zeus-a12-themes-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: A12ResizeNoCredentials())
        settings.typewriterEnabled = false
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), hub = AgentMessagingHub()
        let model = ConversationModel(cards: cards, messaging: hub), panel = ConversationPanelState()
        model.draft = "Retain the caret and draft while the theme changes."
        let host = ConversationHostingView(rootView: ConversationView(settings: settings, store: cards, model: model,
            messaging: hub, status: AvatarStatusModel(cards: cards), panel: panel, activity: SurfaceActivity(),
            openSettings: {}, copySetup: {}, resize: { _ in }))
        host.sizingOptions = []
        let window = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 420, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for scheme in [ColorScheme.light, .dark] {
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for theme in settings.availableThemes {
                #expect(settings.setTheme(id: theme.id))
                for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                #expect(host.resizeHandle.focusColor == NSColor(theme.palette(for: scheme).focusRing), "\(theme.id), \(scheme)")
                #expect(model.draft == "Retain the caret and draft while the theme changes.")
            }
        }
        host.resizeHandle.onResize = { width, _ in
            settings.conversationWidth = width
            panel.width = width
            window.setContentSize(CGSize(width: width, height: 300))
        }
        let width = window.frame.width
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        #expect(window.performKeyEquivalent(with: event), "The hosting view must forward the shortcut even when the editor owns focus")
        #expect(window.frame.width == width + 20)
        #expect(model.draft == "Retain the caret and draft while the theme changes.")
    }

    @Test func widthKeysAndAccessibilityActionsShareTheClampedPersistedPath() throws {
        let handle = ConversationResizeHandle()
        let window = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 420, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = handle
        let suite = "zeus-a12-width-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: A12ResizeNoCredentials())
        defer { window.contentView = nil; window.close(); defaults.removePersistentDomain(forName: suite) }
        var edges: [ConversationWidth.Edge] = [], ended = 0
        handle.edge = .left
        handle.onResize = { width, edge in
            let width = ConversationWidth.clamp(width, screenWidth: 1440)
            settings.conversationWidth = width
            window.setContentSize(CGSize(width: width, height: 200)); edges.append(edge)
        }
        handle.onEnd = { ended += 1 }
        handle.onReset = { settings.conversationWidth = ConversationWidth.minimum; window.setContentSize(CGSize(width: ConversationWidth.minimum, height: 200)) }
        func event(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [.command, .option]) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        #expect(handle.performKeyEquivalent(with: try event(124)))
        #expect(settings.conversationWidth == 440 && window.frame.width == 440)
        #expect(handle.performKeyEquivalent(with: try event(123)))
        #expect(settings.conversationWidth == 420)
        for flags: NSEvent.ModifierFlags in [[], .command, .option, [.command, .option, .shift], [.command, .option, .control]] {
            #expect(!handle.performKeyEquivalent(with: try event(124, flags)))
        }
        #expect(!handle.performKeyEquivalent(with: try event(125)))
        #expect(handle.accessibilityPerformIncrement() && settings.conversationWidth == 440)
        #expect(handle.accessibilityPerformDecrement() && settings.conversationWidth == 420)
        #expect(handle.acceptsFirstResponder && window.makeFirstResponder(handle))
        handle.keyDown(with: try event(124, []))
        #expect(settings.conversationWidth == 440 && handle.accessibilityValueDescription() == "440 points")
        #expect(handle.accessibilityValue() as? NSNumber == 440)
        for _ in 0..<30 { _ = handle.accessibilityPerformIncrement() }
        #expect(settings.conversationWidth == 720 && window.frame.width == 720)
        for _ in 0..<30 { _ = handle.accessibilityPerformDecrement() }
        #expect(settings.conversationWidth == Double(ConversationWidth.minimum))
        #expect(edges.allSatisfy { $0 == .left } && ended == edges.count)
        let reset = try #require(handle.accessibilityCustomActions()?.first)
        #expect(reset.name == "Reset width" && reset.handler?() == true)
        #expect(settings.conversationWidth == Double(ConversationWidth.minimum))
        #expect(handle.menu(for: try event(124))?.items.first?.title == "Reset width")
        let restored = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: A12ResizeNoCredentials())
        #expect(restored.conversationWidth == Double(ConversationWidth.minimum))
        handle.onResize = nil
        #expect(!handle.performKeyEquivalent(with: try event(124)) && !handle.accessibilityPerformIncrement())
    }
}

@MainActor private struct A12ResizeNoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
