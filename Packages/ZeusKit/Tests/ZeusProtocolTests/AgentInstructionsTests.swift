import Testing
import ZeusProtocol

@Test func instructionsExplainSupportedFormattingAckScopeAndTimedOutAsks() throws {
    let guidance = ZeusMCP.instructions
    #expect(!guidance.contains("inline only") && !guidance.contains("No headings, lists or tables"))
    #expect(guidance.contains("first 6 lines") && guidance.contains("Single line breaks are kept"))
    #expect(guidance.contains("earlier_session") && guidance.contains("zeus_say has no card_id"))
    #expect(guidance.contains("delivery_mode") && guidance.contains("actively considering"))
    let ask = try #require(ZeusMCP.tools.first { $0.name == "zeus_ask" })
    #expect(ask.inputSchema["properties"]?["multiline"]?["description"] != nil)
    let update = try #require(ZeusMCP.tools.first { $0.name == "zeus_update_card" })
    #expect(update.description.contains("no inserted space or newline"))
    #expect(!ZeusMCP.tools[0].description.contains("Inline markdown only"))
}
