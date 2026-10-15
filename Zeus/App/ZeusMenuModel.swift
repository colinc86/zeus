import AppKit
import SwiftUI
import ZeusDesign

/// The one Zeus menu (MB1, CONTRACT §10.5): the menu bar icon's menu and the character's right-click menu both render
/// this, so they always have the same items in the same order. `ShellController.menuModel` builds it; `perform` runs an
/// item's action.
struct ZeusMenuModel: Equatable {
    /// What choosing an item does. Plain values, so the model can be compared and tested.
    enum Action: Hashable {
        /// Opens the panel at the waiting question or first unread message (the status strip's jump).
        case openStatusTarget
        case managed(ZeusManagedPresentation.Action)
        /// nil is Auto.
        case selectAssistantSession(String?)
        case talk, askAboutThis, toggleVisibility, hideForHour, hideUntilTomorrow, deliveryProblem
        case character(String), size(AvatarSize), theme(String)
        case settings, checkForUpdates, about, quit
    }

    /// A key equivalent: one lowercase character and its modifiers.
    struct Shortcut: Hashable {
        var key: Character
        var command = false, option = false, control = false, shift = false

        var appKitModifiers: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if command { flags.insert(.command) }; if option { flags.insert(.option) }
            if control { flags.insert(.control) }; if shift { flags.insert(.shift) }
            return flags
        }
        var swiftUI: KeyboardShortcut {
            var modifiers: EventModifiers = []
            if command { modifiers.insert(.command) }; if option { modifiers.insert(.option) }
            if control { modifiers.insert(.control) }; if shift { modifiers.insert(.shift) }
            return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        }
    }

    struct Item: Equatable, Identifiable {
        enum Kind: Equatable {
            /// Plain status text; with an action it can be chosen (the status line's jump).
            case line(Action?)
            case action(Action)
            case submenu([[Item]])
        }
        var id: String
        var title: String
        var kind: Kind
        var shortcut: Shortcut? = nil
        /// Shows a checkmark.
        var isOn = false
        var isEnabled = true
        /// Tooltip.
        var help: String? = nil

        static func line(_ title: String, action: Action? = nil) -> Item {
            Item(id: "line:" + title, title: title, kind: .line(action))
        }
        static func action(_ id: String, _ title: String, _ action: Action, shortcut: Shortcut? = nil, isOn: Bool = false,
                           isEnabled: Bool = true, help: String? = nil) -> Item {
            Item(id: id, title: title, kind: .action(action), shortcut: shortcut, isOn: isOn, isEnabled: isEnabled, help: help)
        }
    }

    /// Sections, top to bottom, separated by dividers.
    var sections: [[Item]]

    /// Every item, depth first, as "title" lines with submenu items indented, for tests and accessibility dumps.
    /// Disabled items end with " (disabled)"; checked ones start with "✓ ".
    var outline: [String] { Self.outline(sections, depth: 0) }

    static func outline(_ sections: [[Item]], depth: Int) -> [String] {
        var lines: [String] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { lines.append(String(repeating: "  ", count: depth) + "—") }
            for item in section {
                let enabled: Bool = if case .line(nil) = item.kind { false } else { item.isEnabled }
                lines.append(String(repeating: "  ", count: depth) + (item.isOn ? "\u{2713} " : "") /* test and dump text, never drawn */ + item.title + (enabled ? "" : " (disabled)"))
                if case .submenu(let children) = item.kind { lines += outline(children, depth: depth + 1) }
            }
        }
        return lines
    }
}

// MARK: - AppKit: the character's right-click menu

extension ZeusMenuModel {
    /// Builds the `NSMenu` for the character. `perform` runs when an item is chosen.
    @MainActor func makeNSMenu(perform: @escaping @MainActor (Action) -> Void) -> NSMenu {
        let target = ZeusMenuTarget(perform: perform)
        return Self.menu(sections, target: target)
    }

    @MainActor private static func menu(_ sections: [[Item]], target: ZeusMenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in section {
                let native = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                native.identifier = NSUserInterfaceItemIdentifier(item.id)
                native.state = item.isOn ? .on : .off
                native.toolTip = item.help
                let action: Action? = switch item.kind {
                case .line(let action): action
                case .action(let action): action
                case .submenu: nil
                }
                switch item.kind {
                case .line, .action:
                    if let action {
                        native.action = #selector(ZeusMenuTarget.choose(_:))
                        native.target = target
                        native.representedObject = ZeusMenuTarget.Box(action)
                        native.isEnabled = item.isEnabled
                    } else {
                        native.isEnabled = false
                    }
                case .submenu(let children):
                    native.submenu = Self.menu(children, target: target)
                    native.isEnabled = item.isEnabled
                }
                if let shortcut = item.shortcut {
                    native.keyEquivalent = String(shortcut.key)
                    native.keyEquivalentModifierMask = shortcut.appKitModifiers
                }
                menu.addItem(native)
            }
        }
        // The menu owns its target for as long as it is shown.
        objc_setAssociatedObject(menu, &ZeusMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }
}

/// The Objective-C target for `NSMenuItem` actions.
@MainActor final class ZeusMenuTarget: NSObject {
    final class Box: NSObject { let action: ZeusMenuModel.Action; init(_ action: ZeusMenuModel.Action) { self.action = action } }
    nonisolated(unsafe) static var key: UInt8 = 0
    let perform: @MainActor (ZeusMenuModel.Action) -> Void
    init(perform: @escaping @MainActor (ZeusMenuModel.Action) -> Void) { self.perform = perform }
    @objc func choose(_ sender: NSMenuItem) {
        if let box = sender.representedObject as? Box { perform(box.action) }
    }
}

// MARK: - SwiftUI: the menu bar icon's menu

/// The `MenuBarExtra` content for a `ZeusMenuModel`.
struct ZeusMenuContent: View {
    let model: ZeusMenuModel
    let perform: @MainActor (ZeusMenuModel.Action) -> Void

    var body: some View { Self.sections(model.sections, perform: perform) }

    @MainActor @ViewBuilder static func sections(_ sections: [[ZeusMenuModel.Item]], perform: @escaping @MainActor (ZeusMenuModel.Action) -> Void) -> some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in ZeusMenuItemView(item: item, perform: perform) }
        }
    }
}

private struct ZeusMenuItemView: View {
    let item: ZeusMenuModel.Item
    let perform: @MainActor (ZeusMenuModel.Action) -> Void

    var body: some View {
        switch item.kind {
        case .line(nil):
            Text(item.title)
        case .line(let action?), .action(let action):
            if item.isOn {
                // A checked item: a Toggle draws the menu's checkmark.
                Toggle(item.title, isOn: Binding(get: { true }, set: { _ in perform(action) }))
                    .modifier(Extras(item: item))
            } else {
                Button(item.title) { perform(action) }.modifier(Extras(item: item))
            }
        case .submenu(let children):
            Menu(item.title) { ZeusMenuContent.sections(children, perform: perform) }.disabled(!item.isEnabled)
        }
    }

    private struct Extras: ViewModifier {
        let item: ZeusMenuModel.Item
        func body(content: Content) -> some View {
            content
                .keyboardShortcut(item.shortcut?.swiftUI)
                .disabled(!item.isEnabled)
                .help(item.help ?? "")
        }
    }
}
