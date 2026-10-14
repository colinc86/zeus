import AppKit
import SwiftUI
import ZeusDesign

struct AboutSettingsView: View {
    static func version(_ info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 80, height: 80).accessibilityHidden(true)
            Text("Zeus").settingsTitle()
            Text(Self.version(Bundle.main.infoDictionary ?? [:]))
            Text("Your desktop companion for personal-assistant agents.")
            Text("Zeus lives in the menu bar. Click the character to talk, drag to move, and right-click for quick controls.").settingsCaption()
        }
    }
}
