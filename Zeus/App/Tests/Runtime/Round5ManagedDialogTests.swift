import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedDialogTests {
    @Test func confirmedReplacementDialogUpdatesTheSameCard() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let first = try managedSnapshot("claude-blocked-permission")
        await f.managed.host.setSnapshot(first)
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let original = try #require(f.cards.values.first)
        let second = ManagedPaneSnapshot(screen: first.screen.replacingOccurrences(of: "Bash command", with: "Edit file").replacingOccurrences(of: "m0-permission.txt", with: "SECOND.txt"), inputMetadata: first.inputMetadata)
        await f.managed.host.setSnapshot(second)
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.cards.card(id: original.id)?.body == original.body)
        f.managed.controller.refresh(); try await f.managed.settle()
        let updated = try #require(f.cards.card(id: original.id))
        #expect(f.cards.values.count == 1 && updated.status == .open)
        #expect(updated.body.contains("SECOND.txt") && !updated.body.contains("Bash command"))
        #expect(updated.options.map(\.label) == original.options.map(\.label) && updated.createdAt == original.createdAt)
        #expect(updated.options.first?.id != original.options.first?.id, "A replacement prompt invalidates the old choice fingerprint")
        #expect(updated.options.last?.id == "open-terminal")
        await f.managed.host.setSnapshot(.init(screen: "", inputMetadata: "0|0|120|0|1"))
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.cards.card(id: original.id)?.body == updated.body)
        let stale = try #require(original.options.first)
        f.cards.respond(id: original.id, option: stale.id)
        #expect(await f.managed.host.promptAnswers.isEmpty, "Stale buttons must never answer the new question")
    }
}
