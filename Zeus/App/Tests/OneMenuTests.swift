import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

// MB1: one menu for the menu bar icon and the character, and a menu bar icon that can be hidden without losing the way
// back. Isolated defaults and history; no global shortcut, runtime or real panels beyond the test host's.

@MainActor private final class OneMenuFixture {
    let suite = "zeus-one-menu-\(UUID())"
    let defaults: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-one-menu-\(UUID())")
    let settings: AppSettings
    let cards: CardStore
    let shell: ShellController

    init() {
        defaults = UserDefaults(suiteName: suite) ?? .standard
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        cards.onAdd = nil
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

/// The `NSMenu` in the same outline form as `ZeusMenuModel.outline`.
@MainActor private func outline(_ menu: NSMenu, depth: Int = 0) -> [String] {
    var lines: [String] = []
    for item in menu.items {
        let indent = String(repeating: "  ", count: depth)
        if item.isSeparatorItem { lines.append(indent + "—"); continue }
        lines.append(indent + (item.state == .on ? "✓ " : "") + item.title + (item.isEnabled ? "" : " (disabled)"))
        if let submenu = item.submenu { lines += outline(submenu, depth: depth + 1) }
    }
    return lines
}

@MainActor @Suite(.serialized) struct OneMenuTests {
    @Test func bothSurfacesShowTheSameItemsInTheSameOrder() throws {
        let f = OneMenuFixture(); defer { f.cleanup() }
        let model = f.shell.menuModel
        // The character's menu is the model, item for item, including submenus, checkmarks and disabled lines.
        #expect(outline(f.shell.makeContextMenu()) == model.outline)
        // The menu bar renders the same model through SwiftUI.
        let hosted = NSHostingMenu(rootView: ZeusMenuContent(model: model) { _ in })
        hosted.update()
        let hostedTitles = hosted.items.filter { !$0.isSeparatorItem }.map(\.title)
        let modelTitles = model.sections.flatMap { $0.map(\.title) }
        #expect(hostedTitles == modelTitles, "\(hostedTitles)")

        let titles = model.sections.map { $0.map(\.title) }
        #expect(titles.count == 5)
        #expect(titles[1] == ["Talk to Zeus…", "Hide Zeus", MenuPresentation.hideForHour, MenuPresentation.hideUntilTomorrow])
        #expect(titles[2] == ["Character", "Size", "Theme"])
        #expect(titles[3].first == "Settings…" && titles[3].last == "About Zeus")
        #expect(titles[4] == ["Quit Zeus"])
        #expect(model.sections[3].first?.shortcut == .init(key: ",", command: true))
        #expect(model.sections[4].first?.shortcut == .init(key: "q", command: true))
        #expect(model.sections[1].first?.shortcut == .init(key: "z", command: true, option: true), "the Talk shortcut")
    }

    @Test func lookSubmenusMarkTheCurrentChoice() throws {
        let f = OneMenuFixture(); defer { f.cleanup() }
        f.settings.setTheme(id: "sorbet")
        let look = f.shell.menuModel.sections[2]
        func children(_ id: String) -> [ZeusMenuModel.Item] {
            guard case .submenu(let sections)? = look.first(where: { $0.id == id })?.kind else { return [] }
            return sections.flatMap { $0 }
        }
        #expect(children("theme").map(\.id) == ZeusThemeLibrary.bundledOrder.map { "theme:" + $0 })
        #expect(children("theme").filter(\.isOn).map(\.id) == ["theme:sorbet"])
        #expect(children("character").filter(\.isOn).map(\.id) == ["character:" + f.settings.currentCharacterID])
        #expect(children("size").filter(\.isOn).map(\.id) == ["size:" + f.settings.avatarSize.rawValue])
        f.shell.perform(.theme("phosphor"))
        #expect(f.settings.currentThemeID == "phosphor")
        f.shell.perform(.size(.large))
        #expect(f.settings.avatarSize == .large)
    }

    @Test func deliveryProblemAndHiddenUntilAppearOnlyWhenTheyApply() throws {
        let f = OneMenuFixture(); defer { f.cleanup() }
        #expect(!f.shell.menuModel.outline.contains("Delivery problem…"))
        f.shell.hide(for: .hour)
        let model = f.shell.menuModel
        #expect(model.sections[0].contains { $0.title.hasPrefix("Hidden until ") })
        #expect(model.sections[1][1].title == "Show Zeus")
    }

    @Test func statusLineSaysWhatTheStripSaysAndJumpsThere() throws {
        let f = OneMenuFixture(); defer { f.cleanup() }
        let question = Card(id: "c_q", kind: .question, title: "Slides", body: "Update or start fresh?",
                            options: [CardOption(id: "u", label: "Update")], sessionKey: "claude:/tmp/a")
        f.cards.add(question)
        f.cards.markAllSeen()
        func jumpLine() -> ZeusMenuModel.Item? { f.shell.menuModel.sections[0].first { $0.kind == .line(.openStatusTarget) } }
        // A managed session keeps its own status first; the strip's sentence follows its actions.
        #expect(jumpLine()?.title == "? Waiting for your answer · Go to question")
        #expect(f.shell.menuModel.sections[0].first?.kind == .line(nil))
        // Connect your own: the strip's sentence is the status line itself.
        f.settings.managedSession?.enabled = false
        #expect(f.shell.menuModel.sections[0].first == jumpLine())
        f.shell.perform(.openStatusTarget)
        #expect(f.shell.cardPanelState.scrollTargetCardID == "c_q")

        f.cards.add(Card(id: "c_new", kind: .message, body: "Fresh news"))
        #expect(jumpLine()?.title == "! Unread · Show")
        #expect(f.shell.menuModel.outline.filter { $0.localizedCaseInsensitiveContains("unread") }.count == 1, "no second unread line")
    }

    @Test func turningTheIconOffWhileHiddenShowsZeusFirst() async throws {
        let f = OneMenuFixture(); defer { f.cleanup() }
        #expect(f.settings.showMenuBarIcon, "on by default")
        for duration in [AvatarVisibilityModel.Duration?.none, .hour, .tomorrow] {
            f.settings.showMenuBarIcon = true
            if let duration { f.shell.hide(for: duration) } else { f.shell.toggleVisibility() }
            #expect(f.shell.visibility.isHidden)
            f.settings.showMenuBarIcon = false
            f.shell.menuBarIconSettingChanged()
            #expect(!f.shell.visibility.isHidden && f.shell.visibility.hiddenUntil == nil)
        }
        // Turning it off while Zeus is showing changes nothing else.
        f.settings.showMenuBarIcon = true
        f.settings.showMenuBarIcon = false
        f.shell.menuBarIconSettingChanged()
        #expect(!f.shell.visibility.isHidden)
        #expect(UserDefaults(suiteName: f.suite)?.bool(forKey: "general.showMenuBarIcon") == false, "persisted")
    }

    @Test func reopeningShowsZeusAndClearsATimedHide() throws {
        let f = OneMenuFixture(); defer { f.cleanup() }
        f.shell.hide(for: .tomorrow)
        #expect(f.shell.visibility.isHidden)
        f.shell.handleReopen()
        #expect(!f.shell.visibility.isHidden && f.shell.visibility.hiddenUntil == nil)
    }

    @Test func captionNamesTheTalkShortcutOnlyWhenItWorks() {
        var hotKey = TalkHotKey()
        #expect(GeneralSettingsView.menuBarIconCaption(hotKey: hotKey)
                == "Right-click Zeus for the same menu. If Zeus is hidden and the icon is off, open Zeus again from Spotlight or Launchpad, or press ⌥⌘Z.")
        hotKey.enabled = false
        #expect(GeneralSettingsView.menuBarIconCaption(hotKey: hotKey).hasSuffix("from Spotlight or Launchpad."))
    }
}
