import Foundation
import Testing
import ZeusProtocol

struct MessageRatingMetadataTests {
    @Test func legacyCardsRemainUnclassifiedAndNewCardsRoundTrip() throws {
        let old = Card(kind: .message, body: "Legacy", createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
        let oldJSON = try ZeusJSON.encoder().encode(old)
        let decoded = try ZeusJSON.decoder().decode(Card.self, from: oldJSON)
        #expect(decoded.origin == nil && decoded.about == nil && decoded.muteDecision == nil)
        var card = old; card.origin = .unprompted; card.about = "On-call reminder"
        card.muteDecision = .init(ratingID: "r1", kindLabel: "On-call reminder", reason: "looks like On-call reminder", engine: "naturalLanguage", score: 0.9, threshold: 0.8, decidedAt: Date(timeIntervalSince1970: 10))
        #expect(try ZeusJSON.decoder().decode(Card.self, from: ZeusJSON.encoder().encode(card)) == card)
    }
    @Test func toolsAdvertiseAboutButNeverAgentControlledOriginOrHold() throws {
        for name in ["zeus_say", "zeus_ask", "zeus_present"] {
            let tool = try #require(ZeusMCP.tools.first { $0.name == name })
            #expect(tool.inputSchema["properties"]?["about"]?["minLength"] == 1)
            #expect(tool.inputSchema["properties"]?["about"]?["maxLength"] == 60)
            #expect(tool.inputSchema["properties"]?["origin"] == nil)
            #expect(tool.inputSchema["properties"]?["muteDecision"] == nil)
        }
    }
}
