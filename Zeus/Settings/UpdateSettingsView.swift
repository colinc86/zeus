import SwiftUI
import ZeusDesign

struct UpdateSettingsView: View {
    let updater: any AppUpdating
    static func automaticChecksBinding(_ updater: any AppUpdating) -> Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text("Updates").settingsTitle()
            Toggle("Automatically check for updates", isOn: Self.automaticChecksBinding(updater))
                .accessibilityLabel("Automatically check for updates")
                .toggleStyle(ZeusCheckboxStyle())
                .disabled(!updater.isAvailable)
            Text(AboutSettingsView.version(Bundle.main.infoDictionary ?? [:])).settingsCaption()
            if let reason = updater.unavailableReason { Text(reason).settingsCaption() }
        }
    }
}
