import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private struct PC1Capture: Decodable {
    let screen: String
    let inputMetadata: String
    var snapshot: ManagedPaneSnapshot { .init(screen: screen, inputMetadata: inputMetadata) }
}
func pc1Snapshot(_ name: String) throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try JSONDecoder().decode(PC1Capture.self, from: Data(contentsOf: root.appendingPathComponent("TestFixtures/panes/claude-2.1/\(name).json"))).snapshot
}

@MainActor
struct PC1PaneTests {
    static let draft = "The sample item was handled earlier.\nKeep this second line as an unsent draft."

    @Test(arguments: ["claude-idle", "claude-draft", "claude-update-idle", "claude-scheduled-idle"])
    func completedTurnsRemainIdleWithDraftsNoticesAndScheduledHistory(name: String) throws {
        let snapshot = try pc1Snapshot(name)
        #expect(ManagedPaneClassifier.classify(snapshot, agent: .claude) == .idle)
        #expect(ManagedPromptParser.parse(snapshot, agent: .claude) == nil)
        let input = try #require(TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8)))
        #expect(input.humanDraftText == (name == "claude-draft" ? Self.draft : nil))
    }
    @Test func spinnerWithAnUpdateFooterIsWorkingWithoutInterruptHint() throws {
        let snapshot = try pc1Snapshot("claude-update-working")
        #expect(ManagedPaneClassifier.classify(snapshot, agent: .claude) == .working)
        #expect(ManagedPromptParser.parse(snapshot, agent: .claude) == nil)
    }
    @Test func permissionWidgetIsBlockedAndParsed() throws {
        let snapshot = try pc1Snapshot("claude-update-permission")
        guard case .blocked = ManagedPaneClassifier.classify(snapshot, agent: .claude) else { Issue.record("Live permission widget must be blocked"); return }
        let prompt = try #require(ManagedPromptParser.parse(snapshot, agent: .claude))
        #expect(prompt.kind == .command && prompt.title == "Bash command")
        #expect(prompt.detail == "printf PC1_DONE > pc1.txt")
        #expect(prompt.question == "Do you want to proceed?" && prompt.options.map(\.label) == ["Yes", "No"])
    }
    @Test(arguments: [AgentKind.codex, .opencode])
    func otherRealIdleComposersPreserveAnUnsentDraft(agent: AgentKind) throws {
        let snapshot = try pc1Snapshot(agent.rawValue + "-draft")
        #expect(ManagedPaneClassifier.classify(snapshot, agent: agent) == .idle)
        #expect(ManagedPromptParser.parse(snapshot, agent: agent) == nil)
        let input = try #require(TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8)))
        #expect(input.humanDraftText == "PC1 unsent draft.")
    }
    @Test(arguments: ["esc to interrupt", "✔ Update installed · Restart to update", "Warning: loading development channels\n❯ 1. I am using this for local development\n2. Exit"])
    func footerTextCannotTurnAnIdleComposerIntoWorkOrADialog(footer: String) throws {
        var snapshot = try pc1Snapshot("claude-draft")
        snapshot.screen += footer + "\n"
        #expect(ManagedPaneClassifier.classify(snapshot, agent: .claude) == .idle)
        #expect(ManagedPromptParser.parse(snapshot, agent: .claude) == nil)
    }
    @Test func centeredOpenCodeMutedHintIsNotAHumanDraftButMovingHomeDoesNotEraseTypedText() throws {
        var snapshot = try pc1Snapshot("opencode-draft")
        snapshot.inputMetadata = "26|20|120|0|1|"
        let typed = try #require(TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8)))
        #expect(typed.humanDraftText == "PC1 unsent draft.")
        snapshot.screen = snapshot.screen.replacingOccurrences(of: "PC1 unsent draft.", with: "\u{1b}[2mAsk anything\u{1b}[22m")
        let hint = try #require(TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8)))
        #expect(hint.humanDraftText == nil)
    }
    @Test(arguments: ["✔ Update installed · Restart to update", "A custom status line\nAnother footer row\nAnother row\nOne more footer row"])
    func footerAfterConfirmationControlsDoesNotChangeThePromptIdentity(footer: String) throws {
        var snapshot = try pc1Snapshot("claude-update-permission")
        let original = try #require(ManagedPromptParser.parse(snapshot, agent: .claude))
        snapshot.screen += footer + "\n"
        guard case .blocked = ManagedPaneClassifier.classify(snapshot, agent: .claude) else { Issue.record("Footer must not hide a live permission widget"); return }
        #expect(ManagedPromptParser.parse(snapshot, agent: .claude)?.fingerprint == original.fingerprint)
        #expect(ManagedPromptParser.parse(snapshot, agent: .claude)?.options == original.options)
    }
    @Test func controllerKeepsTheRealMultilineDraftForTheP2Alert() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle(); f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try pc1Snapshot("claude-draft"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.idle))
        #expect(f.controller.latestInputSample?.draftText == Self.draft)
    }
    @Test(arguments: ["claude-idle", "claude-draft"])
    func recordedIdleAfterWorkEndsTheThinkingRow(name: String) async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        #expect(await f.runtime.sendUserMessage("PC1 finish this turn", deliveryID: "d_pc1") == .delivered)
        await f.managed.host.setSnapshot(try pc1Snapshot("claude-update-working"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        await f.managed.host.setSnapshot(try pc1Snapshot(name))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.managed.controller.managedStatus == .running(.idle))
        #expect(f.runtime.assistantActivity == nil)
        #expect(f.managed.controller.latestInputSample?.draftText == (name == "claude-draft" ? Self.draft : nil))
    }
}
