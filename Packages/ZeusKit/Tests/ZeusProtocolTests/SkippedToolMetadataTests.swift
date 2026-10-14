import Testing
import ZeusProtocol

@Test func skippedQuestionsHaveAgentGuidanceInInstructionsAndTools() throws {
    #expect(ZeusMCP.instructions.contains("{status:\"skipped\", card_id}"))
    #expect(ZeusMCP.instructions.contains("reply | skipped | userMessage"))
    #expect(ZeusMCP.instructions.contains("Don't re-ask; proceed with your best judgement or move on."))
    for name in ["zeus_ask", "zeus_get_responses"] {
        let tool = try #require(ZeusMCP.tools.first { $0.name == name })
        #expect(tool.description.contains("skipped"))
        #expect(tool.description.contains("don't re-ask; proceed with your best judgement or move on"))
    }
}
