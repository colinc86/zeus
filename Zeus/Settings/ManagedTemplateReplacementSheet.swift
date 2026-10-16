import SwiftUI
import ZeusDesign

struct ManagedTemplateReplacementSheet: View {
    let replace: @MainActor () -> Void
    let cancel: @MainActor () -> Void
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Replace your edits?").settingsTitle()
            Text("Using the new templates replaces AGENTS.md and CLAUDE.md in your assistant folder, including your edits. Everything else in the folder stays. Your assistant restarts to read them.").settingsBody()
            HStack {
                KeyboardButton("Replace", action: replace).buttonStyle(ZeusButtonStyle(.destructive, size: .small)).accessibilityLabel("Replace edited assistant template")
                KeyboardButton("Cancel", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel template replacement")
            }
        }.padding(20).frame(width: 480).fixedSize(horizontal: false, vertical: true)
            .environment(\.zeusFontChoice, .system).environment(\.zeusFontScale, .default).onAppear { cancelFocused = true }
    }
}
