import SwiftUI
import ZeusDesign

/// Settings › Appearance (T1): the color theme and the conversation font. Its own tab, beside Character, because like
/// Character it's a library you browse, import into and edit live, and General was already the longest pane.
struct AppearanceSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var importer: LibraryImportModel

    init(settings: AppSettings) {
        self.settings = settings
        _importer = State(initialValue: .themes(settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Theme").settingsTitle()
            Text("Colors for the conversation, Zeus's speech bubble and Settings. Characters keep their own colors.").settingsCaption()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(settings.availableThemes) { theme in
                    ThemeCard(theme: theme, selected: settings.currentThemeID == theme.id) { settings.setTheme(id: theme.id) }
                }
            }
            LibraryFileActions(model: importer)
            Text("Your own themes are JSON files in the Themes folder. Open Example to see how one is made; Zeus picks up changes as soon as you save.")
                .settingsCaption()
            ForEach(Array(settings.themeProblemLines.enumerated()), id: \.offset) { _, line in
                if line.isError { Text(line.text).settingsError() } else { Text(line.text).settingsCaption() }
            }
            SettingsDivider()
            SettingsSegments(label: "Conversation font", options: ZeusFontChoice.allCases.map { ($0, $0.displayName) }, selection: $settings.fontChoice)
        }
    }
}

/// One theme in the picker: its name, a strip of its colors as they'd show right now, and a "Low contrast" tag.
private struct ThemeCard: View {
    let theme: ZeusThemeDefinition
    let selected: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        let colors = theme.palette(for: colorScheme, contrast: contrast)
        KeyboardButton(action: choose) {
            // The Zeus field frame; the chosen theme gets the gold focus frame, like the character picker.
            ZeusFieldChrome(isFocused: selected) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(theme.name).settingsBody().lineLimit(1)
                        Spacer(minLength: 0)
                        if theme.isLowContrast {
                            Text("Low contrast").zeusFont(.badge).foregroundStyle(palette.destructive)
                                .padding(.horizontal, 4).overlay(Rectangle().strokeBorder(palette.destructive, lineWidth: 1))
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(Self.swatches(colors).enumerated()), id: \.offset) { _, color in
                            Rectangle().fill(color).frame(height: 18)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(colors.outline, lineWidth: 1))
                    .accessibilityHidden(true)
                    Text(subtitle).settingsCaption().lineLimit(1)
                    if let caption = ZeusThemeImport.lowContrastCaption(theme) {
                        Text(caption).settingsCaption().lineLimit(1).help(theme.contrastProblems.joined(separator: "\n"))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(([theme.name, subtitle] + (theme.isLowContrast ? ["Low contrast"] : [])).joined(separator: ". "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Panel, text, accent, the assistant's bubble and the user's bubble.
    static func swatches(_ p: ZeusPalette) -> [Color] { [p.panel, p.text, p.accent, p.agentBubble, p.userBubble] }

    private var subtitle: String {
        let look = switch theme.fixedAppearance {
        case .dark?: "Always dark"
        case .light?: "Always light"
        default: "Follows your Mac"
        }
        return theme.author.map { "\(look) · by \($0)" } ?? look
    }
}

extension LibraryImportModel {
    /// Settings › Appearance's Import Theme…, Open Example and Open Themes Folder.
    static func themes(_ settings: AppSettings) -> LibraryImportModel {
        LibraryImportModel(kind: Kind(
            importTitle: "Import Theme…", folderTitle: "Open Themes Folder",
            panelMessage: "Choose a theme file (.json).",
            directory: { [weak settings] in settings?.userThemeDirectory },
            plan: { [weak settings] data, source, directory in
                let builtIn = ZeusThemeLibrary.load(userDirectory: nil).themes
                switch ZeusThemeImport.plan(data: data, source: source, userDirectory: directory, builtIn: builtIn) {
                case .failure(let failure): return .failure(LineFailure(lines: failure.lines))
                case .success(let plan):
                    let id = plan.theme.id
                    return .success(Plan(prompt: plan.conflict.map(ZeusThemeImport.replacePrompt), done: ZeusThemeImport.doneMessage(plan),
                                         notes: ZeusThemeImport.lowContrastCaption(plan.theme).map { [$0] } ?? [],
                                         install: { try ZeusThemeImport.install(plan, into: $0) },
                                         select: { settings?.setTheme(id: id) }))
                }
            },
            writeExample: { try ZeusThemeExample.write(into: $0) },
            reload: { [weak settings] in settings?.reloadThemes() }
        ))
    }
}

extension AppSettings {
    /// Problems in theme files as Settings lists them: one line per file that didn't load, with every reason.
    var themeProblemLines: [(text: String, isError: Bool)] {
        let errors = Dictionary(grouping: themeProblems.filter { $0.severity == .error }, by: \.source)
        let failed = errors.keys.sorted().map { file in
            (text: "\(file) wasn't loaded. " + (errors[file] ?? []).map(\.message).joined(separator: " "), isError: true)
        }
        let warnings = themeProblems.filter { $0.severity == .warning && errors[$0.source] == nil }
            .map { (text: "\($0.source): \($0.message)", isError: false) }
        return failed + warnings
    }
}
