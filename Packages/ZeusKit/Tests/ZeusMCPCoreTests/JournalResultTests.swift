import Testing
import ZeusProtocol
@testable import ZeusMCPCore

struct JournalResultTests {
    @Test func approvedJournalPictureBecomesMCPImageWithoutChangingExactText() throws {
        let value: JSONValue = ["answer_id": "journal_answer_test", "items": [["picture": ["mimeType": "image/jpeg", "data": "AQID"]]]]
        let result = try ToolResult(structured: value)
        let rpc = JSONRPC.toolResult(result)
        guard case .array(let content) = rpc["content"] else { Issue.record("Missing content"); return }
        #expect(content.count == 2)
        #expect(content[0]["text"] == .string(result.text))
        #expect(content[1] == ["type": "image", "mimeType": "image/jpeg", "data": "AQID"])
        #expect(rpc["structuredContent"] == value)
        guard case .array(let errorContent) = JSONRPC.toolResult(try .init(structured: value, isError: true))["content"] else { Issue.record("Missing content"); return }
        #expect(errorContent.count == 1)
    }
}
