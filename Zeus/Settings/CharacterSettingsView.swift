import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign

struct CharacterSettingsView: View {
    @Bindable var settings: AppSettings
    let resetPosition: () -> Void
    @State private var importer: CharacterImportModel
    @State private var choosingFile = false
    @FocusState private var cancelFocused: Bool
    @Environment(\.zeusPalette) private var palette

    init(settings: AppSettings, resetPosition: @escaping () -> Void) {
        self.settings = settings
        self.resetPosition = resetPosition
        _importer = State(initialValue: CharacterImportModel(settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Characters").settingsTitle()
            SettingsSegments(label: "Size", options: AvatarSize.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $settings.avatarSize)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(settings.availableCharacters) { character in
                    Button { settings.currentCharacterID = character.id } label: {
                        // The Zeus field frame; the chosen character gets the gold focus frame.
                        ZeusFieldChrome(isFocused: settings.currentCharacterID == character.id) {
                            VStack(spacing: 8) {
                                CharacterAnimationView(character: character, state: .idle, scale: 1)
                                    .frame(width: 96, height: 112)
                                Text(character.name).settingsBody().lineLimit(1)
                            }.frame(maxWidth: .infinity).frame(height: 140)
                        }
                    }.buttonStyle(.plain).help(character.summary)
                        .accessibilityLabel(character.name + ". " + character.summary)
                        .accessibilityAddTraits(settings.currentCharacterID == character.id ? [.isSelected] : [])
                }
            }
            HStack(spacing: 8) {
                Button("Import Character…") { chooseFile() }.accessibilityLabel("Import Character…").disabled(choosingFile)
                Button("Open Example") { open(try? importer.exampleFile()) }.accessibilityLabel("Open Example")
                Button("Open Characters Folder") { open(try? importer.charactersFolder()) }.accessibilityLabel("Open Characters Folder")
            }
            if let prompt = importer.replacePrompt { replaceConfirmation(prompt) }
            notice
            Text("Your own characters are JSON files in the Characters folder. Open Example to see how one is made; Zeus picks up changes as soon as you save.")
                .settingsCaption()
            ForEach(Array(settings.characterProblemLines.enumerated()), id: \.offset) { _, line in
                if line.isError { Text(line.text).settingsError() } else { Text(line.text).settingsCaption() }
            }
            SettingsDivider()
            Button("Reset Avatar Position", action: resetPosition).accessibilityLabel("Reset Avatar Position")
            Toggle("Fade Zeus when idle", isOn: $settings.fadeZeusWhenIdle).settingsBody()
            if settings.fadeZeusWhenIdle {
                HStack {
                    Text("Idle opacity").settingsBody()
                    Slider(value: $settings.idleOpacity, in: 0.1...0.9, step: 0.01)
                        .tint(palette.focusRing)
                        .accessibilityLabel("Idle opacity")
                        .accessibilityValue("\(Int((settings.idleOpacity * 100).rounded())) percent")
                    Text("\(Int((settings.idleOpacity * 100).rounded()))%").settingsBody().monospacedDigit()
                }
                HStack {
                    Text("Fade after").settingsBody()
                    Slider(value: $settings.idleFadeDelay, in: 5...600, step: 5)
                        .tint(palette.focusRing)
                        .accessibilityLabel("Idle fade delay")
                        .accessibilityValue("\(Int(settings.idleFadeDelay)) seconds")
                    Text(settings.idleFadeDelay < 60 ? "\(Int(settings.idleFadeDelay)) s" : "\(Int(settings.idleFadeDelay / 60)) min \(Int(settings.idleFadeDelay.truncatingRemainder(dividingBy: 60))) s")
                        .settingsBody().monospacedDigit()
                }
                Text("Point at Zeus to bring it back. Clicks still work while faded. Questions, work and open conversations keep Zeus visible.").settingsCaption()
            }
        }
    }

    @ViewBuilder private var notice: some View {
        switch importer.notice {
        case .added(let message, let notes)?:
            Text(message).settingsBody()
            ForEach(notes, id: \.self) { Text($0).settingsCaption() }
        case .failed(let file, let lines)?:
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't add \(file).").settingsError()
                ForEach(lines, id: \.self) { Text($0).settingsError() }
            }
        case nil:
            EmptyView()
        }
    }

    /// Replacing is the risky choice, so Cancel has focus and Esc (as in Settings › Assistant's confirmations).
    private func replaceConfirmation(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text(prompt).zeusFont(.caption).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZeusTheme.Spacing.s) {
                Button("Replace") { importer.confirmReplace() }.accessibilityLabel("Replace")
                    .buttonStyle(ZeusButtonStyle(.destructive, size: .small)).focusable()
                Button("Cancel") { importer.cancelReplace() }.accessibilityLabel("Cancel")
                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    .focusable().focused($cancelFocused).keyboardShortcut(.cancelAction)
            }
        }
        .padding(ZeusTheme.Spacing.s).background(palette.field)
        .onAppear { cancelFocused = true }
    }

    private func chooseFile() {
        guard !choosingFile else { return }
        choosingFile = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"; panel.message = "Choose a character file (.json)."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            choosingFile = false
            if response == .OK, let url = panel.url { importer.importFile(at: url) }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    /// Opens a file in its default app (or a folder in Finder); shows it in Finder when nothing can open it.
    private func open(_ url: URL?) {
        guard let url else { return }
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
