import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5RecoveredActionTests {
    @Test func recoveredTerminalActionOpensDuringGraceWithoutAnswering() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        let cards = CardStore(fileURL: f.folder.appendingPathComponent("cards.json"), clock: { f.clock.now })
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: FakeRouting(),
            clock: f.clock, socketPath: f.folder.appendingPathComponent("runtime.sock").path,
            ledgerURL: f.folder.appendingPathComponent("deliveries.json"), connectors: [], managedController: f.controller)
        try runtime.start(); defer { runtime.stop() }
        try await f.settle(); f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.controller.refresh(); try await f.settle() }
        let card = try #require(cards.cards.first)
        runtime.stop(); try runtime.start(); try await f.settle()
        #expect(runtime.managedStatus == .starting)
        #expect(cards.respond(id: card.id, response: .init(optionID: "open-terminal", device: .mac)))
        try await f.settle()
        #expect(f.terminal.files.count == 1)
        #expect(cards.card(id: card.id)?.status == .open && cards.card(id: card.id)?.response == nil)
        f.clock.advance(10, wake: false)
        for _ in 0..<2 { f.controller.refresh(); try await f.settle() }
        #expect(runtime.managedBlockedCardID == card.id && cards.cards.count == 1)
        #expect(cards.card(id: card.id)?.status == .open && runtime.ledger?.records.isEmpty == true)
    }
    @Test func aPreviouslyResolvedCurrentCardCannotHideANewBlock() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let old = try #require(f.runtime.managedBlockedCardID)
        f.cards.update(id: old) { $0.status = .answered }
        f.runtime.updateManagedPresentation()
        #expect(f.runtime.managedBlockedCardID != old)
        #expect(f.cards.values.last?.status == .open && f.cards.values.last?.options.first?.id == "open-terminal")
    }
}
