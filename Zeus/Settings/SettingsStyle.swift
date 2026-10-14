import SwiftUI
import ZeusDesign

// One type system for Settings (D2-3): Zeus fonts and palette everywhere. Settings applies
// `ZeusButtonStyle(.secondary, size: .small)` and `ZeusCheckboxStyle` to all its content, so panes only
// mark the exceptions (a primary button) and use these text styles.

private struct SettingsText: ViewModifier {
    enum Role { case title, heading, body, caption, error }
    let role: Role
    @Environment(\.zeusPalette) private var palette

    func body(content: Content) -> some View {
        switch role {
        case .title: content.zeusFont(.title).foregroundStyle(palette.title).accessibilityAddTraits(.isHeader)
        case .heading: content.zeusFont(.button).foregroundStyle(palette.text).accessibilityAddTraits(.isHeader)
        case .body: content.zeusFont(.body).foregroundStyle(palette.text)
        case .caption: content.zeusFont(.caption).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
        case .error: content.zeusFont(.caption).foregroundStyle(palette.destructive).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// A section title ("Talk shortcut").
    func settingsTitle() -> some View { modifier(SettingsText(role: .title)) }
    /// A step or group heading inside a section.
    func settingsHeading() -> some View { modifier(SettingsText(role: .heading)) }
    /// Ordinary Settings text and control labels.
    func settingsBody() -> some View { modifier(SettingsText(role: .body)) }
    /// A one- or two-line explanation under a control.
    func settingsCaption() -> some View { modifier(SettingsText(role: .caption)) }
    /// An error under a control.
    func settingsError() -> some View { modifier(SettingsText(role: .error)) }
}

/// A short choice as Zeus buttons, the selected one gold (replaces segmented pickers).
struct SettingsSegments<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            Text(label).settingsBody()
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
                    .buttonStyle(ZeusButtonStyle(selection == option.value ? .primary : .secondary, size: .small))
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The pixel rule between Settings sections.
struct SettingsDivider: View {
    @Environment(\.zeusPalette) private var palette
    var body: some View { Rectangle().fill(palette.fieldBorder).frame(height: ZeusTheme.pixel).accessibilityHidden(true) }
}
