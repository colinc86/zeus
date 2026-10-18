import SwiftUI
import ZeusDesign

/// The shared pause and destructive action come after every observation level, not inside Level 1.
struct JournalPrivacyActions: View {
    let learn: LearnFromMe
    let enabled: Bool
    let delete: (Bool) -> Void
    @State private var confirming = false
    @State private var includeAssistantNotes = false
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
            KeyboardButton("Delete Everything…") { includeAssistantNotes = false; confirming = true }
                .buttonStyle(ZeusButtonStyle(.destructive, size: .small)).accessibilityLabel("Delete Everything")
        }
        .sheet(isPresented: $confirming) {
            DeleteLearningConfirmation(includeAssistantNotes: $includeAssistantNotes,
                cancel: { confirming = false }, delete: { delete(includeAssistantNotes); confirming = false })
        }
    }
}

struct DeleteLearningConfirmation: View {
    @Binding var includeAssistantNotes: Bool
    let cancel: @MainActor () -> Void
    let delete: @MainActor () -> Void
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete everything Zeus kept and sent?").settingsTitle()
            Text("This removes what Zeus kept here and the files Zeus wrote in Zeus/ inside your assistant's folder. Anything else in that folder stays. This can't be undone.").settingsBody()
            Toggle("Also delete your assistant's notes", isOn: $includeAssistantNotes)
                .toggleStyle(ZeusCheckboxStyle()).accessibilityLabel("Also delete your assistant's notes")
            Text("Everything in its Notes folder is deleted, including files you or your assistant put there.").settingsCaption()
            HStack {
                Spacer()
                KeyboardButton("Cancel", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel")
                KeyboardButton("Delete", action: delete).buttonStyle(ZeusButtonStyle(.destructive, size: .small)).accessibilityLabel("Delete")
            }
        }.padding(24).frame(width: 480).fixedSize(horizontal: false, vertical: true)
            .onAppear { cancelFocused = true }
    }
}
