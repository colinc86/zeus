import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedPresentationTests {
    @Test func failedBlockedResolutionRetriesAfterHistoryRepair() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        let path = f.folder.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: path, clock: { f.clock.now })
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: FakeRouting(),
            clock: f.clock, socketPath: f.folder.appendingPathComponent("runtime.sock").path,
            ledgerURL: f.folder.appendingPathComponent("deliveries.json"), connectors: [], managedController: f.controller)
        try runtime.start(); defer { runtime.stop() }
        try await f.settle(); f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.controller.refresh(); try await f.settle() }
        let id = try #require(runtime.managedBlockedCardID)
        let saved = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        await f.host.setSnapshot(try managedSnapshot("claude-idle"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.idle))
        #expect(cards.card(id: id)?.status == .open && runtime.managedBlockedCardID == id)
        #expect(cards.persistenceError != nil)
        try FileManager.default.removeItem(at: path)
        try saved.write(to: path)
        #expect(cards.retryPersistence())
        f.controller.refresh(); try await f.settle()
        #expect(runtime.managedBlockedCardID == nil && cards.card(id: id)?.status == .answered)
        #expect(CardStore(fileURL: path).card(id: id)?.body == "Answered in Terminal")
    }
}
