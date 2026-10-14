import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

func updateSnapshot(_ name: String) throws -> ManagedPaneSnapshot {
    struct Frame: Decodable { var screen: String; var inputMetadata: String }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let frame = try JSONDecoder().decode(Frame.self, from: Data(contentsOf: root.appendingPathComponent("TestFixtures/panes/claude-2.1/claude-update-\(name).json")))
    return .init(screen: frame.screen, inputMetadata: frame.inputMetadata)
}

@MainActor struct ManagedAgentUpdateTests {
    @Test(arguments: ["idle", "working", "permission"])
    func recordedFooterIsNotHistoryOrADialog(name: String) throws {
        let sample = try updateSnapshot(name)
        #expect(ManagedPaneClassifier.agentUpdatePending(sample, agent: .claude) == (name != "permission"))
        for agent in [AgentKind.codex, .opencode, .other] {
            #expect(!ManagedPaneClassifier.agentUpdatePending(sample, agent: agent))
        }
    }
    @Test func historicalAndDraftUpdateTextNeverDetects() throws {
        let sample = try updateSnapshot("idle")
        let without = sample.screen.replacingOccurrences(of: "✔ Update installed · Restart to update", with: "")
        let history = ManagedPaneSnapshot(screen: "✔ Update installed · Restart to update\n" + without,
            inputMetadata: "2|13|120|0|0|")
        #expect(!ManagedPaneClassifier.agentUpdatePending(history, agent: .claude))
        let draft = ManagedPaneSnapshot(screen: "────────────────\n❯ ✔ Update installed · Restart to update\n────────────────\nmanual mode", inputMetadata: "4|1|120|0|1")
        #expect(!ManagedPaneClassifier.agentUpdatePending(draft, agent: .claude))
        #expect(!ManagedPaneClassifier.agentUpdatePending(.init(screen: sample.screen, inputMetadata: "invalid"), agent: .claude))
    }
    private func ready(_ f: ManagedFixture) async throws {
        f.controller.activate(); try await f.settle(); try f.connectOwned()
        f.clock.advance(10, wake: false)
    }
    private func sample(_ frame: ManagedPaneSnapshot, _ f: ManagedFixture) async throws {
        await f.host.setSnapshot(frame); f.controller.refresh(); try await f.settle()
    }
    @Test func debounceClearsOnOneMissingSampleAndStop() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        try await ready(f)
        let update = try updateSnapshot("idle")
        try await sample(update, f); #expect(!f.controller.managedAgentUpdatePending)
        try await sample(update, f); #expect(f.controller.managedAgentUpdatePending)
        try await sample(try N1Messages.frame(.claude, "before"), f)
        #expect(!f.controller.managedAgentUpdatePending)
        try await sample(update, f); #expect(!f.controller.managedAgentUpdatePending)
        try await sample(update, f); #expect(f.controller.managedAgentUpdatePending)
        f.controller.stopManagedSession(); try await f.settle()
        #expect(!f.controller.managedAgentUpdatePending)
    }
    @Test(arguments: ["working", "draft", "blocked", "delivery"])
    func explicitUpdateWaitsAndResumesSameIdentityWithoutChangingSettings(state: String) async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        try await ready(f)
        let update = try updateSnapshot("idle")
        try await sample(update, f); try await sample(update, f)
        let identity = try #require(f.controller.record?.conversation)
        switch state {
        case "working": try await sample(try updateSnapshot("working"), f)
        case "draft":
            var draft = update
            draft.screen = draft.screen.replacingOccurrences(of: "❯ ", with: "❯ draft")
            try await sample(draft, f)
        case "blocked": f.controller.settingsApplicationAllowed = { false }
        default: f.controller.settingsApplicationAllowed = { false }
        }
        // A deferred UI switch must never be used for the update restart.
        f.config.value?.agent = .codex
        f.controller.restartManagedAgentForUpdate(); try await f.settle()
        if state == "blocked" {
            try await sample(try managedSnapshot("claude-blocked-permission"), f)
            try await sample(try managedSnapshot("claude-blocked-permission"), f)
        }
        #expect(await f.host.stops == 0)
        #expect(f.controller.managedSettingsApplication?.kind == .agentUpdate)
        f.controller.settingsApplicationAllowed = { true }
        try await sample(try N1Messages.frame(.claude, "before"), f)
        #expect(await f.host.stops == 1)
        #expect(await f.host.commands.count == 2)
        #expect(f.controller.record?.conversation?.nativeID == identity.nativeID)
        #expect(f.controller.record?.conversation?.nonce == identity.nonce)
        #expect(f.controller.record?.conversation?.agent == .claude)
        #expect(!f.controller.managedAgentUpdatePending)
        #expect(f.controller.managedSettingsApplication == nil)
        let command = try #require(await f.host.commands.last).arguments
        let nativeID = try #require(identity.nativeID)
        #expect(command.contains("--resume") && command.contains(nativeID))
        #expect(!command.contains(identity.firstMessage))
    }
    @Test func absentUpdateCannotRestartAndQueuedUpdateCancelsOnStop() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        try await ready(f)
        f.controller.restartManagedAgentForUpdate(); try await f.settle()
        #expect(await f.host.stops == 0)
        let update = try updateSnapshot("idle")
        try await sample(update, f); try await sample(update, f)
        f.controller.settingsApplicationAllowed = { false }
        f.controller.restartManagedAgentForUpdate()
        f.controller.stopManagedSession(); try await f.settle()
        #expect(f.controller.managedSettingsApplication == nil)
        #expect(await f.host.commands.count == 1)
    }
}
