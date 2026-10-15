import SwiftUI
import ZeusDesign

/// The shared pause and destructive action come after every observation level, not inside Level 1.
struct JournalPrivacyActions: View {
    let learn: LearnFromMe
    let enabled: Bool
    let delete: () -> Void
    @State private var confirming = false
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if enabled {
                HStack {
                    if learn.isPausedNow { Text("Paused until tomorrow.").settingsCaption() }
                    KeyboardButton(learn.isPausedNow ? "Resume" : "Pause for Today") {
                        if learn.isPausedNow { learn.resume() } else { learn.pauseForToday() }
                    }.accessibilityLabel(learn.isPausedNow ? "Resume" : "Pause for Today")
                }
            }
            if confirming {
                Text("Delete everything Zeus kept and sent? This can't be undone.").settingsBody()
                HStack {
                    KeyboardButton("Cancel", focus: $cancelFocused) { confirming = false }.keyboardShortcut(.cancelAction)
                    KeyboardButton("Delete") { delete(); confirming = false }.buttonStyle(ZeusButtonStyle(.destructive, size: .small))
                }.onAppear { cancelFocused = true }
            } else {
                KeyboardButton("Delete Everything…") { confirming = true }.buttonStyle(ZeusButtonStyle(.destructive, size: .small))
            }
        }
    }
}
