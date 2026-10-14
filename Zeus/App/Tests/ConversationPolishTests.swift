import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

struct ConversationPolishTests {
    @Test func sessionRunsContinueAcrossRepliesAndChangeOnlyWithTheAgent() {
        let a = Card(id: "a", kind: .message, body: "A", sessionKey: "claude:/a")
        let b = Card(id: "b", kind: .message, body: "B", sessionKey: "claude:/a")
        let c = Card(id: "c", kind: .message, body: "C", sessionKey: "codex:/a")
        let d = Card(id: "d", kind: .message, body: "D", sessionKey: "claude:/a")
        let cards = [a,b,c,d]
        let entry: (Card) -> ConversationEntry = { .init(id: "card:\($0.id)", timestamp: $0.createdAt, content: .agentCard($0)) }
        let user = ConversationEntry(id: "answer:a", timestamp: Date(), content: .userAnswer(cardID: "a", response: CardResponse(text: "Reply", device: .mac)))
        #expect(ConversationLayout.sessionLabelEntries([entry(a), user, entry(b), entry(c), entry(d)], cards: cards) == ["card:a", "card:c", "card:d"])
    }
    @Test func historicalParserPreservesHashesAndFormatsOnlyValidatedProcessSuffixes() {
        let label = SessionLabels.displayLabel(key: "claude:/work/notes#draft/Zeus#7208.1791826260000000", sessions: [])
        #expect(label == "Claude · Zeus")
        #expect(!label.contains("1791826260000000"))
        #expect(SessionLabels.displayLabel(key: "claude:/work/notes#draft", sessions: []).contains("notes#draft"))
    }
    @Test func peekConfirmsOnlyTheChosenOptionAndNamesOverflowActionsTruthfully() {
        #expect(!PeekContent.optionDisabled(optionID: "yes", answeredOptionID: "yes"))
        #expect(PeekContent.optionDisabled(optionID: "no", answeredOptionID: "yes"))
        #expect(!PeekContent.optionDisabled(optionID: "no", answeredOptionID: nil))
        let options = (0..<4).map { CardOption(id: "\($0)", label: "\($0)") }
        #expect(PeekContent.secondaryActionLabel(Card(kind: .question, body: "Pick", options: options)) == "Choose…")
        #expect(PeekContent.secondaryActionLabel(Card(kind: .question, body: "Pick", options: options, input: InputSpec())) == "Reply…")
    }
    @Test func attachmentSubtitleShowsTheParentLocationInsteadOfRepeatingItsName() {
        #expect(AttachmentTarget.locationCaption(for: Attachment(kind: .file, label: "Report", target: "/Projects/Q3/report.md")) == "/Projects/Q3")
        #expect(AttachmentTarget.locationCaption(for: Attachment(kind: .folder, label: "Structure", target: "/Projects/Q3/structure")) == "/Projects/Q3")
    }
}
