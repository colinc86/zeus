import SwiftUI
import ZeusDesign

struct CharacterSettingsView: View {
    @Bindable var settings: AppSettings
    let resetPosition: () -> Void
    @State private var importer: LibraryImportModel

    init(settings: AppSettings, resetPosition: @escaping () -> Void) {
        self.settings = settings
        self.resetPosition = resetPosition
        _importer = State(initialValue: .characters(settings))
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
            LibraryFileActions(model: importer)
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
}
