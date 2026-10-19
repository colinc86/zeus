import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct AttachmentSummaryTests {
    let synopsis = "The draft explains the launch plan and highlights the decisions to review."
    func arguments(_ tool: String, attachments: [JSONValue]) -> JSONValue {
        if tool == "zeus_say" { return ["text": "The launch plan is ready for review.", "attachments": .array(attachments)] }
        return ["title": "Launch plan", "body": "The launch plan is ready for review.", "attachments": .array(attachments)]
    }
    func attachment(_ kind: String, summary: JSONValue? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["kind": .string(kind), "label": "Draft", "target": kind == "url" ? "https://example.com/draft" : "/tmp/zeus-synthetic-draft"]
        item["summary"] = summary
        return .object(item)
    }
    @Test(arguments: ["zeus_say", "zeus_present"], ["file", "folder"])
    func missingOrShortSynopsisRejectsWholeCall(tool: String, kind: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        var additions = 0; f.cards.onAdd = { _ in additions += 1 }
        let invalid: [JSONValue?] = [nil, "", " \t\n\u{00a0}", .string(String(repeating: "x", count: 19) + " \n\t")]
        for summary in invalid {
            let result = await f.call(tool, arguments(tool, attachments: [attachment("url"), attachment(kind, summary: summary)]))
            #expect(result.isError)
            let count: Int
            if case .string(let text) = summary { count = text.filter { !$0.isWhitespace }.count } else { count = 0 }
            #expect(result.structured?["error"] == .string("attachments[1].summary (Draft) needs at least 20 non-whitespace characters; it has \(count). " + ToolArguments.attachmentSummaryGuidance))
            #expect(f.cards.values.isEmpty && additions == 0)
        }
    }
    @Test(arguments: ["zeus_say", "zeus_present"])
    func boundariesLinksAndEdits(tool: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        for kind in ["file", "folder", "url"] {
            let tooLong = await f.call(tool, arguments(tool, attachments: [attachment(kind, summary: .string(String(repeating: "x", count: 401)))]))
            #expect(tooLong.isError && f.cards.values.isEmpty)
        }
        let wrongTypes: [JSONValue] = [.null, 4, false]
        for bad in wrongTypes {
            #expect(await f.call(tool, arguments(tool, attachments: [attachment("file", summary: bad)])).isError)
            #expect(f.cards.values.isEmpty)
        }
        let unicode = String(repeating: "界 ", count: 20)
        let result = await f.call(tool, arguments(tool, attachments: [attachment("file", summary: .string(unicode)), attachment("folder", summary: .string(String(repeating: "a", count: 400))), attachment("url")]))
        #expect(!result.isError)
        let card = try #require(f.cards.values.last)
        #expect(card.attachments.map(\.summary) == [unicode, String(repeating: "a", count: 400), nil])
        #expect(!(await f.call("zeus_update_card", ["card_id": .string(card.id), "text": "Updated takeaway."])).isError)
        #expect(f.cards.card(id: card.id)?.attachments == card.attachments)
        #expect(await f.call("zeus_update_card", ["card_id": .string(card.id), "attachments": []]).isError)
        #expect(f.cards.card(id: card.id)?.attachments == card.attachments)
    }
}
