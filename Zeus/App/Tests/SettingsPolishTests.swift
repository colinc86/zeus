import Foundation
import SwiftUI
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct SettingsPolishTests {
    @Test func publicSettingsIncludeAboutAndOmitUnimplementedRemote() {
        let labels = SettingsTab.allCases.map(\.rawValue)
        #expect(labels.contains("About") && !labels.contains("Remote"))
        #if DEBUG
        #expect(labels.contains("Debug"))
        #else
        #expect(!labels.contains("Debug"))
        #endif
        #expect(AboutSettingsView.version(["CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "3"]) == "Version 0.1.2 (3)")
    }
    @Test func setupGuideIncludesLaunchRoutingVerificationAndConfigMerge() {
        let guide = SetupCommands.guide(bridgePath: "/Applications/Zeus.app/Contents/MacOS/zeus-mcp")
        #expect(guide.contains("claude mcp add -s user"))
        #expect(guide.contains("tmux new-session -s codex codex"))
        #expect(guide.contains("opencode --port 4096"))
        #expect(guide.contains("~/.config/opencode/opencode.json"))
        #expect(guide.contains("keeping your other settings"))
        #expect(guide.contains("OpenCode conversation"))
        #expect(guide.contains("say hi through Zeus"))
    }
    @Test func startupFailureIsDistinctFromAnOfflineAssistantAndCanRetry() async {
        let hub = AgentMessagingHub()
        hub.startupError = "The bridge socket is already in use."
        let result = await hub.sendUserMessage("Keep this")
        guard case .failed(let reason) = result else { Issue.record("A missing runtime cannot durably queue"); return }
        #expect(reason == "Zeus isn't connected to your assistant. Retry, or check Settings → Assistant.")
        #expect(hub.startupError == "The bridge socket is already in use.")
        #expect(hub.startupRecoveryHint.contains("other copy"))
        hub.startupError = "The delivery data could not be read."
        #expect(hub.startupRecoveryHint.contains("backup") && !hub.startupRecoveryHint.contains("other copy"))
        var retries = 0
        hub.retryStartup = { retries += 1 }
        hub.retryAgentLink()
        #expect(retries == 1)
    }
    @Test func menuUsesPlainStatusAndTheConfiguredShortcut() {
        #expect(MenuPresentation.status(state: .alert, unread: 2, activity: nil) == "2 new messages")
        #expect(MenuPresentation.status(state: .waiting, unread: 0, activity: nil) == "Waiting for your answer")
        #expect(MenuPresentation.status(state: .idle, unread: 0, activity: nil) == "Ready to talk")
        var key = TalkHotKey()
        #expect(key.menuShortcut?.modifiers == [.command, .option])
        key.enabled = false
        #expect(key.menuShortcut == nil)
        key.keyCode = UInt32.max; key.enabled = true
        #expect(key.menuShortcut == nil)
    }
    @Test func clearHistoryPreservesOpenAndPendingAndRemovesTheirOldSeenMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-clear-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cards = CardStore(fileURL: url)
        let completed = Card(kind: .message, body: "Completed", status: .dismissed)
        let open = Card(kind: .question, body: "Still waiting")
        let pending = Card(kind: .question, body: "Answered, not delivered", status: .answered)
        for card in [completed, open, pending] { cards.add(card); cards.markSeen(id: card.id); cards.markRevealed(id: card.id) }
        cards.pendingHistoryIDs = { [pending.id] }
        #expect(cards.clearConversation())
        #expect(Set(cards.cards.map(\.id)) == [open.id, pending.id])
        #expect(!cards.seenIDs.contains(completed.id) && !cards.revealedIDs.contains(completed.id))
        #expect(CardStore(fileURL: url).cards.map(\.id) == cards.cards.map(\.id))
    }
    @Test func clearFailureDoesNotPublishOrOverwriteTheSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-clear-\(UUID())")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: url)
        cards.add(Card(kind: .message, body: "Keep", status: .dismissed))
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        #expect(!cards.clearConversation())
        #expect(cards.cards.count == 1)
        #expect(try Data(contentsOf: url) == original)
    }
}
