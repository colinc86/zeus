import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct RuntimeRecoveryTests {
    @Test func waitingAssistantBindingRetriesPersistenceWithoutSendingUnsavedRouting() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        if case .queued = await f.runtime.sendUserMessage("Save before connect") {} else { Issue.record("Expected queued") }
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        let original = try Data(contentsOf: f.runtime.ledgerURL)
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        try FileManager.default.createDirectory(at: f.runtime.ledgerURL, withIntermediateDirectories: true)
        f.connect()
        #expect(f.connector.deliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: id)?.awaitingAssistant == true)
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        try original.write(to: f.runtime.ledgerURL)
        f.clock.advance(3)
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        let saved = try #require(DeliveryLedger(location: f.runtime.ledgerURL).record(id: id))
        #expect(saved.awaitingAssistant == nil && saved.delivery.sessionKey == "claude:/assistant")
        #expect(saved.delivery.attempts == 1 && saved.delivery.id == id)
    }

    @Test func reconnectFlushFromOldGenerationDoesNotBurnANewRuntimeAttempt() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let bridgeID = UUID()
        let processKey = "claude:/assistant#123.456"
        f.connector.hold = true; f.connect(processKey, id: bridgeID)
        let original = Task { await f.runtime.sendUserMessage("Keep one attempt") }
        try await eventually { f.connector.waits.count == 1 }
        // This registration waits for the old in-flight send before flushing.
        f.connect(processKey, id: bridgeID)
        f.runtime.stop()
        try f.runtime.start()
        f.connect(processKey, id: bridgeID)
        try await eventually { f.connector.waits.count == 2 }
        // Finish the new generation first, then let the canceled old send complete.
        f.connector.waits.removeLast().resume()
        try await eventually { f.runtime.sends.isEmpty }
        f.connector.hold = false; f.connector.release()
        _ = await original.value
        // Drain the continuation tasks awakened by the old completion.
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.connector.deliveries.count == 2)
        #expect(f.runtime.ledger?.records.first?.delivery.attempts == 2)
    }
}
