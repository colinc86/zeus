import SwiftUI
import ZeusDesign

struct LearningFolderView: View {
    @Bindable var model: LearningFolderModel
    var managed: Bool
    var openAssistant: @MainActor () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your assistant's folder").settingsHeading()
            Text(model.path.map { "Kept in " + $0 } ?? (managed ? "Not kept in a folder yet. Choose your assistant's folder under Assistant." : "Not kept in a folder. Choose one and Zeus writes what it keeps there for your assistant."))
                .settingsBody().textSelection(.enabled)
                .accessibilityLabel("Your assistant's folder, " + (model.path.map { "kept in " + $0 } ?? "no folder chosen"))
            HStack {
                if model.folderURL != nil {
                    KeyboardButton("Show in Finder", action: model.showFolder).accessibilityLabel("Show assistant's folder in Finder")
                }
                if managed && model.folderURL == nil {
                    KeyboardButton("Assistant Settings", action: openAssistant).accessibilityLabel("Assistant Settings")
                }
                if !managed {
                    KeyboardButton("Choose…", action: model.choose).disabled(model.provider == nil)
                        .accessibilityLabel("Choose learnings folder")
                    if model.folderURL != nil {
                        KeyboardButton("Stop keeping a folder", action: model.stopKeepingFolder)
                            .accessibilityLabel("Stop keeping a learnings folder")
                    }
                }
            }
            if model.writeFailed { Text("Zeus can't write to this folder.").settingsError() }
            Text("Where this folder lives is up to you. If it syncs, what Zeus keeps syncs with it.").settingsCaption()
        }
    }
}

struct CoverPicturesConfirmation: View {
    let keepCovering: @MainActor () -> Void
    let turnOff: @MainActor () -> Void
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep pictures uncovered?").settingsTitle()
            Text("Zeus will keep screenshots as they are, with pictures, faces and text uncovered. Passwords, keys, card and account numbers and ID numbers are still covered, and Zeus still never takes a picture of a password dialog, a private window or an app on your private list. Pictures already kept stay covered.").settingsBody()
            HStack {
                Spacer()
                KeyboardButton("Keep Covering", focus: $cancelFocused, action: keepCovering)
                    .keyboardShortcut(.cancelAction).accessibilityLabel("Keep Covering")
                KeyboardButton("Turn Off", action: turnOff).buttonStyle(ZeusButtonStyle(.destructive, size: .small))
                    .accessibilityLabel("Turn off picture covering")
            }
        }.padding(24).frame(width: 480).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain).accessibilityLabel("Keep pictures uncovered?").onAppear { cancelFocused = true }
    }
}
