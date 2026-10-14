import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedBlockEndTests {
    @Test(arguments: ["stop", "clean-exit", "crash", "disable", "idle", "working"])
    func onlyPositivePaneEvidenceSaysAnswered(end: String) async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let id = try #require(f.runtime.managedBlockedCardID)
        switch end {
        case "stop": f.runtime.stopManagedSession()
        case "clean-exit": await f.managed.host.die(status: 0); f.managed.controller.refresh()
        case "crash": await f.managed.host.die(); f.managed.controller.refresh()
        case "disable": f.managed.config.value?.enabled = false; f.managed.controller.configurationChanged()
        default:
            await f.managed.host.setSnapshot(try managedSnapshot(end == "idle" ? "claude-idle" : "claude-working"))
            f.managed.controller.refresh()
        }
        try await f.managed.settle()
        let card = try #require(f.cards.card(id: id))
        #expect(card.status == .answered && card.options.isEmpty && card.response == nil)
        let answered = end == "idle" || end == "working"
        #expect((card.body == "Answered in Terminal") == answered)
        #expect((card.title == "Terminal prompt answered") == answered)
        #expect(f.runtime.ledger?.records.isEmpty == true)
    }
}
