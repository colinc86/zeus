import Foundation
import Testing
@testable import ZeusProtocol

struct AttachmentSummaryTests {
    @Test func legacyDecodeAndSummaryRoundTrip() throws {
        let legacy = Data(#"{"id":"a1","kind":"file","label":"Draft","target":"/tmp/draft.md"}"#.utf8)
        var attachment = try ZeusJSON.decoder().decode(Attachment.self, from: legacy)
        #expect(attachment.summary == nil)
        attachment.summary = "The draft explains the plan and highlights decisions to review."
        #expect(try ZeusJSON.decoder().decode(Attachment.self, from: ZeusJSON.encoder().encode(attachment)) == attachment)
    }
}
