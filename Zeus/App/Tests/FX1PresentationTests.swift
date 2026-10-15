import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct FX1PresentationTests {
    @Test(arguments: ["would have ", "WOULD HAVE ", "would've ", "Would’ve ", "I'd have ", "I would have ", ""])
    func shadowNoticeAndRulesCaptionAreSentences(prefix: String) async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Buy the usual coffee beans", kind: .acts)], at: f.clock.now).first)
        let rest = "bought the usual coffee beans for €14"
        let raw = prefix + rest
        let result = await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(rule.id), "wouldHave": .string(raw)], sessionKey: "claude:/fixture#123.1")
        #expect(!result.isError)
        let notice = try #require(f.cards.learningNotices.first { $0.id.hasPrefix("action:") })
        #expect(notice.summary == "I'd have " + rest)
        #expect(notice.actionTitle == "OK next time?")
        #expect(f.rules.ruleActions.first?.text == raw, "Presentation must not change durable approval identity")
        let model = RulesPaneModel(store: f.rules, journal: JournalViewerModel(journal: f.journal))
        #expect(model.shadowCaption(rule) == "Seen once: would have " + rest)
    }

    @Test func currencyUsesSymbolsAndKeepsFractionalCents() {
        let locale = Locale(identifier: "en_IE")
        #expect(ZeusRuntime.formattedRuleAmount(14, currency: "EUR", locale: locale) == "€14")
        #expect(ZeusRuntime.formattedRuleAmount(14.5, currency: "EUR", locale: locale) == "€14.50")
        #expect(ZeusRuntime.formattedRuleAmount(14.05, currency: "EUR", locale: locale) == "€14.05")
    }

    @Test(arguments: [14.0, 14.5])
    func purchaseQuestionAndNoticeShareCurrencyFormatting(amount: Double) async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Buy coffee", trigger: .init(kind: "spend"), kind: .acts)], at: f.clock.now).first)
        let raw = "would have bought coffee"
        let result = await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(rule.id), "wouldHave": .string(raw), "amount": .number(amount), "currency": "EUR"], sessionKey: "claude:/fixture#123.1")
        #expect(!result.isError)
        let action = try #require(f.rules.ruleActions.first)
        let amountText = ZeusRuntime.formattedRuleAmount(amount, currency: "EUR")
        #expect(f.cards.card(id: try #require(action.approvalCardID))?.body == raw + " — " + amountText)
        #expect(f.cards.learningNotices.first { $0.id == "action:" + action.id }?.summary == "I'd have bought coffee — " + amountText)
        #expect(action.amount == amount && action.currency == "EUR")
        f.cards.respond(id: try #require(action.approvalCardID), option: "approve", label: "Approve this purchase")
        let acted = await f.runtime.callTool("zeus_rule_acted", arguments: ["ruleID": .string(rule.id), "did": .string(raw), "approvalID": .string(action.id)], sessionKey: "claude:/fixture#123.1")
        #expect(!acted.isError, "The same approved action must still match exactly")
    }

    @Test func normalizationOnlyRemovesALeadingCompletePhrase() {
        #expect(ZeusRuntime.shadowActionText("sent what I would have written") == "sent what I would have written")
        #expect(ZeusRuntime.shadowActionText("would havebeen different") == "would havebeen different")
        #expect(ZeusRuntime.shadowActionText("  WOULD HAVE\n sent a recap  ") == "sent a recap")
        #expect(ZeusRuleTools.tools.first { $0.name == "zeus_rule_shadow" }?.description.contains("past participle") == true)
    }
}
