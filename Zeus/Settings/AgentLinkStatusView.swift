import AppKit
import SwiftUI
import ZeusProtocol

struct AgentLinkStatusView: View {
    let hub: AgentMessagingHub
    var body: some View {
        if !hub.previewEnabled, hub.runtime == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Zeus couldn’t start its connection to your assistant.").settingsHeading()
                if let reason = hub.startupError { Text(reason).settingsCaption().textSelection(.enabled) }
                Text(hub.startupRecoveryHint).settingsCaption()
                Button("Show Zeus Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([ZeusPaths.cards.deletingLastPathComponent()]) }.accessibilityLabel("Show Zeus Data Folder")
                if hub.retryStartup != nil { Button("Try Again") { hub.retryAgentLink() }.accessibilityLabel("Try Again") }
            }
        }
    }
}
