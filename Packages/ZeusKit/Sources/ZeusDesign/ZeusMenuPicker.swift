import SwiftUI

/// A pop-up picker in Zeus chrome: the current choice in a field well with a chevron, opening the platform menu.
/// Use it for long or changing lists (sessions, Terminal panes, OpenCode conversations); short fixed choices
/// read better as `ZeusChoiceList` or segments. `noneTitle` adds a first item that selects `nil`, e.g.
/// "Auto (newest)" or "Choose a pane".
public struct ZeusMenuPicker<ID: Hashable & Sendable>: View {
    public var label: String
    public var showsLabel: Bool
    public var choices: [ZeusChoice<ID>]
    public var noneTitle: String?
    public var placeholder: String
    @Binding public var selection: ID?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - label: The visible label before the menu (hidden with `showsLabel: false`); always VoiceOver's label.
    ///   - choices: The menu items, in order. A disabled choice shows but can't be picked; its `detail` is a second line.
    ///   - selection: The chosen ID, or `nil`.
    ///   - noneTitle: When set, a first item that selects `nil`, and what the field shows for `nil`.
    ///   - placeholder: What the field shows for `nil` without a `noneTitle`, or for an ID that isn't in `choices`.
    public init(_ label: String, choices: [ZeusChoice<ID>], selection: Binding<ID?>, noneTitle: String? = nil,
                placeholder: String = "Choose…", showsLabel: Bool = true) {
        self.label = label
        self.choices = choices
        self._selection = selection
        self.noneTitle = noneTitle
        self.placeholder = placeholder
        self.showsLabel = showsLabel
    }

    /// The text in the field for `selection`.
    nonisolated static func displayTitle(selection: ID?, choices: [ZeusChoice<ID>], noneTitle: String?, placeholder: String) -> String {
        guard let selection else { return noneTitle ?? placeholder }
        return choices.first { $0.id == selection }?.title ?? placeholder
    }

    /// Whether the field shows a real choice (text color) or a prompt (secondary color).
    nonisolated static func showsChoice(selection: ID?, choices: [ZeusChoice<ID>], noneTitle: String?) -> Bool {
        guard let selection else { return noneTitle != nil }
        return choices.contains { $0.id == selection }
    }

    public var body: some View {
        let title = Self.displayTitle(selection: selection, choices: choices, noneTitle: noneTitle, placeholder: placeholder)
        let chosen = Self.showsChoice(selection: selection, choices: choices, noneTitle: noneTitle)
        HStack(spacing: ZeusTheme.Spacing.s) {
            if showsLabel { Text(label).zeusFont(.body).foregroundStyle(palette.text).fixedSize() }
            Menu {
                if let noneTitle { item(noneTitle, detail: nil, selected: selection == nil, enabled: true) { selection = nil } }
                ForEach(choices) { choice in
                    item(choice.title, detail: choice.detail, selected: selection == choice.id, enabled: choice.isEnabled) { selection = choice.id }
                }
            } label: {
                HStack(spacing: ZeusTheme.Spacing.s) {
                    Text(title).foregroundStyle(chosen ? palette.text : palette.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                }
                .modifier(ZeusFieldChromeModifier())
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(label)
            .accessibilityValue(title)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    @ViewBuilder private func item(_ title: String, detail: String?, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        // A toggle is how platform menus draw the checkmark on the current item.
        Toggle(isOn: Binding(get: { selected }, set: { _ in action() })) {
            Text(title)
            if let detail { Text(detail) }
        }
        .disabled(!enabled)
    }
}
