import Foundation
import Testing
@testable import Zeus

private struct FixedTopicModel: TypingTopicGenerating {
    let value: TypingTopic
    func generate(app: String, words: String) async -> TypingTopic? { value }
}

@Suite struct TypingTopicChecksTests {
    @Test(arguments: ["AI assistant", "an AI assistant", "Coding Agent", "assistant", "a bot", "unknown role"])
    func recipientsCannotDiscardSubject(_ recipient: String) async {
        let value = TypingTopic(app: "Warp", intent: .drafting, subject: "Guitar arrangement feedback", recipients: [recipient])
        let checked = TopicSummarizer.check(value, app: "Warp")
        #expect(checked.subjectRejection == nil)
        #expect(checked.topic.subject == "Guitar arrangement feedback")
        #expect(checked.droppedRecipients == (recipient == "unknown role" ? 1 : 0))
        let payload = await TopicSummarizer(model: FixedTopicModel(value: value)).summarize(
            .init(app: .init("Warp"), words: .init("Synthetic guitar feedback"), wordCount: 3))
        #expect(payload.value.topic == "Guitar arrangement feedback")
    }

    @Test func placeholdersPreserveRemainingSubjectAndUnsafeRecipientsAreDropped() {
        let checked = TopicSummarizer.check(.init(app: "Warp", intent: .drafting,
            subject: "‹name› Guitar arrangement feedback ‹secret›",
            recipients: ["john@example.test", "manager", "agent 42"]), app: "Warp")
        #expect(checked.topic.subject == "Guitar arrangement feedback")
        #expect(checked.topic.recipients == ["manager"])
        #expect(checked.droppedRecipients == 2)
        #expect(checked.subjectRejection == nil)
    }

    @Test func subjectRejectReasonsRemainSpecificAndPrivate() {
        let cases: [(String, TopicSummarizer.SubjectRejection)] = [
            ("‹name›", .empty), ("Drafting in Warp", .generic), ("Typing in Warp.", .generic),
            ("Guitar ‹name", .placeholder), ("Version 42 review", .number),
            ("Email john@example.test", .privateDetail), ("Meet John Smith", .privateDetail),
            ("Discuss a synthetic change to the current project with john@example.test", .privateDetail)
        ]
        for (subject, reason) in cases {
            let checked = TopicSummarizer.check(.init(app: "Warp", intent: .drafting,
                subject: subject, recipients: ["manager"]), app: "Warp")
            #expect(checked.subjectRejection == reason)
            #expect(checked.topic.subject == "Drafting in Warp")
            #expect(checked.topic.recipients == ["manager"])
        }
    }

    @Test func legacyRejectionReasonsExplainSyntheticLoss() {
        // The previous all-fields predicate, retained only to reproduce the regression.
        let roles: Set<String> = ["manager", "colleague"]
        let cases = [
            ("Guitar arrangement feedback", "AI assistant", "unknown recipient"),
            ("Song riff refinement", "coding agent", "unknown recipient"),
            ("Code review", "agent 42", "number"),
            ("‹name› Guitar arrangement feedback", "manager", "placeholder"),
            ("Email john@example.test", "manager", "private detail"),
            ("", "manager", "empty")
        ]
        for (subject, recipient, expected) in cases {
            let strings = [subject, recipient]
            let reason: String
            if subject.isEmpty { reason = "empty" }
            else if strings.contains(where: { $0.contains("‹") }) { reason = "placeholder" }
            else if strings.contains(where: { $0.contains(where: \.isNumber) }) { reason = "number" }
            else if strings.contains(where: { LocalRedactor.firstPass($0).report.total > 0 }) { reason = "private detail" }
            else if !roles.contains(recipient) { reason = "unknown recipient" }
            else { reason = "accepted" }
            #expect(reason == expected)
        }
    }

    @Test @MainActor func typingExportContainsTopicOnce() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true); defer { f.stop() }
        let writer = try #require(f.folder)
        writer.enabledLevels = { [.typed] }
        try f.journal.append(.init(id: "typing-topic", time: f.clock.now, level: .typed, kind: .typedText,
            payload: .init(.init(description: "Guitar arrangement feedback", topic: "Guitar arrangement feedback"))))
        await writer.flush()
        let file = try #require(writer.folderURL).appendingPathComponent("Zeus/days/2026-10-14/typing.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "Guitar arrangement feedback").count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_FX13_MODEL"] == "1"))
    func syntheticNativeModelEvidence() async {
        for words in [
            "Please help refine the guitar arrangement. The chorus needs contrasting riffs and a gentler transition into the bridge.",
            "Review the song riffs and suggest a tighter melodic response between the rhythm and lead guitar.",
            "Please review this code change for cancellation races and suggest regression tests."
        ] {
            guard let value = await OnDeviceTypingTopic.shared.generate(app: "Warp", words: words) else {
                print("FX13 model unavailable, busy, or failed"); continue
            }
            let checked = TopicSummarizer.check(value, app: "Warp")
            print("FX13 synthetic model: \(value.subject) | recipients=\(value.recipients) | rejection=\(String(describing: checked.subjectRejection)) | dropped=\(checked.droppedRecipients) | after=\(checked.topic.subject)")
        }
    }
}
