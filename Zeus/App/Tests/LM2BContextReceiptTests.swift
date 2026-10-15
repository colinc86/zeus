import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct LM2BContextReceiptTests {
    @Test func queuedIntentSurvivesRestartAndOnlyReceiptCreatesExactDeduplicatedLedger() throws {
        let name = "zeus-context-ledger-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cards.json"), journal = LM2JournalFake()
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        let presentation = LearningPresentation(defaults: defaults, learn: learn)
        presentation.install(journal: journal, rules: LM2RulesFake(), redactor: LocalRedactor(useOnDeviceModel: false), source: LM2FocusSource())
        defer { presentation.stop() }
        let attachment = Attachment(kind: .file, label: "Window · Example.swift", target: "/fixture/window.txt")
        let intent = try #require(ContextSendIntent(cardID: "message", body: "Exactly sent\nAttachments:\n- file: file:///fixture/window.txt",
            items: [.init(attachment: attachment, kind: .window, preview: "Covered fixture")]))
        let original = CardStore(fileURL: file)
        #expect(original.addOutgoing(.init(id: "message", kind: .userMessage, body: intent.body, attachments: [attachment]), deliveryID: "delivery", context: intent))
        #expect(original.setOutgoingState(.queued("Waiting"), cardID: "message"))
        #expect(journal.records.isEmpty)
        let restored = CardStore(fileURL: file)
        restored.onContextReceipt = { presentation.recordContextReceipt(key: $0, intent: $1) }
        #expect(restored.contextIntents["delivery:delivery"]?.body == intent.body)
        let receipt = LearningContextDeliveryReceipt(deliveryID: "delivery", cardID: nil, deliveredAt: Date(), agent: "claude", sessionLabel: "Claude · Fixture", sessionID: "opaque-hash")
        journal.fails = true; restored.recordLearningContextReceipt(receipt)
        #expect(journal.records.isEmpty); #expect(restored.contextIntents["delivery:delivery"]?.receipt != nil)
        journal.fails = false
        let retry = CardStore(fileURL: file)
        retry.onContextReceipt = { presentation.recordContextReceipt(key: $0, intent: $1) }
        retry.retryContextReceipts(); retry.recordLearningContextReceipt(receipt)
        #expect(journal.records.count == 1)
        #expect(journal.records[0].payload.value.text == intent.body)
        #expect(journal.records[0].payload.value.description == "Attached: Window")
        #expect(journal.records[0].payload.value.details["sessionLabel"] == "Claude · Fixture")
        #expect(retry.contextIntents.isEmpty)
    }
    @Test func answerIntentIsCommittedBeforeSynchronousRuntimeReceiptAndFailedHistoryNeverRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-context-answer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cards.json"), cards = CardStore(fileURL: file)
        cards.add(.init(id: "q", kind: .question, body: "Question", input: .init()))
        let intent = try #require(ContextSendIntent(cardID: "q", body: "Answer with a covered picture", items: [
            .init(attachment: .init(kind: .file, label: "Picture · Editor", target: "/fixture/picture.heic"), kind: .picture, preview: "Covered")]))
        var routed = 0
        cards.responseHandler = { _, _ in
            routed += 1
            #expect(CardStore(fileURL: file).contextIntents["card:q"] == intent)
        }
        #expect(cards.respond(id: "q", response: .init(text: intent.body, device: .mac), context: intent)); #expect(routed == 1)
        #expect(!cards.respond(id: "q", response: .init(text: "Duplicate", device: .mac), context: intent)); #expect(routed == 1)
        let failed = CardStore(fileURL: root.appendingPathComponent("unwritable/cards.json"))
        try Data([0]).write(to: root.appendingPathComponent("unwritable"))
        #expect(!failed.addOutgoing(.init(id: "m", kind: .userMessage, body: intent.body), deliveryID: "d", context: intent))
        #expect(failed.contextIntents.isEmpty)
    }
}
