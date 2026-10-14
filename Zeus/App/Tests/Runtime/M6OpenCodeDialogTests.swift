import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct M6OpenCodeDialogTests {
    @Test(arguments: [false, true])
    func updateModalNeverReceivesPasteOrEnter(afterPaste: Bool) async throws {
        let idle = try m6OpenCodeSnapshot("m6-opencode-idle-not-ready")
        let blocked = try m6OpenCodeSnapshot("m6-opencode-update-dialog")
        let runner = ManagedDialogRunner(frames: afterPaste ? [idle, idle, blocked] : [blocked])
        let routing = FakeRouting()
        let context = DeliveryRoutingContext(settings: routing, assistantSessionKey: "managed", tmuxSocketPath: "/tmp/managed-fixture.sock")
        context.managedMethod = .tmux; context.managedPane = "%owned"; context.managedInputAllowed = { true }
        let session = connectorSession(agent: .opencode, pane: "%owned")
        await #expect(throws: ConnectorError.inputBusy) {
            try await TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
                .deliver(Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Hold for the update modal"), to: session, bridge: nil, routing: context)
        }
        let calls = await runner.calls
        #expect(!calls.contains { $0.contains("send-keys") })
        #expect(calls.contains { $0.contains("paste-buffer") } == afterPaste)
    }
    @Test func updateProducesOneAlertCardAndResolvesAfterSkip() async throws {
        let f = try ManagedDeliveryFixture(agent: .opencode); defer { f.cleanup() }
        await f.managed.finder.setID("ses_managed")
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(try m6OpenCodeSnapshot("m6-opencode-update-dialog"))
        for _ in 0..<3 { f.managed.controller.refresh(); try await f.managed.settle() }
        let card = try #require(f.cards.values.first)
        #expect(f.cards.values.count == 1 && card.priority == .high && card.mood == .alert)
        #expect(card.options.first?.id == "open-terminal" && f.status.state == .alert)
        _ = await f.runtime.sendUserMessage("Wait for Skip", deliveryID: "d_update")
        #expect(f.tmux.deliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: "d_update")?.delivery.attempts == 0)
        await f.managed.host.setSnapshot(try m6OpenCodeSnapshot("m6-opencode-idle-not-ready"))
        f.managed.controller.refresh(); try await f.managed.settle()
        try await eventually { f.tmux.deliveries.count == 1 }
        #expect(f.cards.card(id: card.id)?.status == .answered)
        #expect(f.cards.card(id: card.id)?.body == "Answered in Terminal")
        #expect(f.status.state == nil)
    }
    @Test func updateOverlayWinsOverIdleAndWorkingUnderneath() throws {
        let live = try m6OpenCodeSnapshot("m6-opencode-update-dialog")
        for screen in [live.screen, live.screen + "\nesc interrupt"] {
            let value = ManagedPaneClassifier.classify(.init(screen: screen, inputMetadata: live.inputMetadata), agent: .opencode)
            guard case .blocked(let reason, let dialog) = value else { Issue.record("Update modal: \(value)"); return }
            #expect(reason.contains("Update Available"))
            #expect(dialog.contains("update now?"))
        }
        let noControls = live.screen.replacingOccurrences(of: "Confirm", with: "Dismissed")
        #expect(ManagedPaneClassifier.classify(.init(screen: noControls, inputMetadata: live.inputMetadata), agent: .opencode) == .idle)
    }
    @Test func updateModalDebouncesAndStopsInputUntilCleared() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        await f.host.setSnapshot(try m6OpenCodeSnapshot("m6-opencode-update-dialog"))
        f.clock.advance(10, wake: false)
        f.controller.refresh(); try await f.settle()
        #expect(!f.controller.canAcceptInput)
        f.controller.refresh(); try await f.settle()
        guard case .blocked(let reason) = f.controller.managedStatus else { Issue.record("\(f.controller.managedStatus)"); return }
        #expect(reason.contains("Update Available"))
        #expect(!f.controller.canAcceptInput)
        await f.host.setSnapshot(try m6OpenCodeSnapshot("m6-opencode-idle-not-ready"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.idle))
        #expect(f.controller.canAcceptInput && f.controller.mayResolveBlockedCard)
    }
}
