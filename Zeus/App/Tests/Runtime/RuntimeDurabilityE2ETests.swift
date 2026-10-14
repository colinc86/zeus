import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

// Reuse the existing real-process harness without changing appdev-owned files.
extension ZeusE2ETests {
    @Test @MainActor func durableAnswerAndBoundedPollAcrossRealBridgeAndAppRestart() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let bridge = try await f.bridge()
        let asked = try await bridge.call("zeus_ask", ["text": "Survive the handoff", "wait_seconds": 0])
        let id = try e2eString(asked["card_id"])
        f.cards.responseHandler = nil // App dies after saving the answer, before invoking runtime.
        try f.answer(id, text: "Recovered across restart")
        try f.restart()
        try await eventually { f.runtime.sessions.count == 1 }
        let recovered = try await bridge.call("zeus_get_responses")
        #expect(recovered["items"]?[0]?["text"] == "Recovered across restart")
        try await eventually { f.runtime.ledger?.records.first?.delivery.ackedAt != nil }
        let text = String(repeating: "p", count: 90_000)
        for _ in 0..<30 {
            let d = Delivery(kind: .userMessage, sessionKey: f.key(), content: text, createdAt: f.clock.now)
            try f.runtime.ledger?.insert(.init(delivery: d, userText: text))
        }
        var ids: Set<String> = []; var batches = 0
        while ids.count < 30 {
            let result = try await bridge.call("zeus_get_responses")
            guard case .array(let items) = result["items"] else { throw E2EFailure("Missing polling batch") }
            #expect(!items.isEmpty)
            for item in items { #expect(ids.insert(try e2eString(item["delivery_id"])).inserted) }
            batches += 1
            try await eventually { f.runtime.ledger?.records.filter { $0.delivery.ackedAt != nil }.count == ids.count + 1 }
        }
        #expect(batches > 1)
        #expect(try await bridge.call("zeus_get_responses")["items"] == [])
        try await bridge.finish()
    }
}
