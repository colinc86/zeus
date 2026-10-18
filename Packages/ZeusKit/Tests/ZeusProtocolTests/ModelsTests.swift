import Foundation
import Testing
@testable import ZeusProtocol

private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
    let data = try ZeusJSON.encoder().encode(value)
    #expect(try ZeusJSON.decoder().decode(T.self, from: data) == value)
}
private let date = Date(timeIntervalSince1970: 1_700_000_000.125)

@Test func allModelRoundTrips() throws {
    for value in AvatarState.allCases { try roundTrip(value) }
    for value in AgentKind.allCases { try roundTrip(value) }
    for value in Card.Kind.allCases { try roundTrip(value) }
    for value in Card.Priority.allCases { try roundTrip(value) }
    for value in Card.Status.allCases { try roundTrip(value) }
    for value in CardOption.Style.allCases { try roundTrip(value) }
    for value in Attachment.Kind.allCases { try roundTrip(value) }
    for value in CardResponse.Device.allCases { try roundTrip(value) }
    for value in Delivery.Kind.allCases { try roundTrip(value) }
    let option = CardOption(id: "yes", label: "Yes", style: .primary)
    let input = InputSpec(placeholder: "Your answer", multiline: true)
    let attachment = Attachment(id: "a_123", kind: .file, label: "Draft", target: "~/draft.key")
    let response = CardResponse(optionID: "yes", optionLabel: "Yes", text: "With revisions", respondedAt: date, device: .ios)
    try roundTrip(option); try roundTrip(input); try roundTrip(attachment); try roundTrip(response)
    try roundTrip(Card(id: "c_12345678", kind: .question, title: "Ready?", body: "**Review** this", options: [option], input: input,
                       attachments: [attachment], progress: 0.25, priority: .high, mood: .waiting, sessionKey: "claude:/test",
                       createdAt: date, updatedAt: date, expiresAt: date, status: .answered, response: response))
    try roundTrip(Card(kind: .message, body: "Hello", createdAt: date, updatedAt: date))
    try roundTrip(Delivery(id: "d_12345678", kind: .reply, cardID: "c_12345678", sessionKey: "claude:/test", content: "Yes",
                          meta: ["kind": "reply", "delivery_id": "d_12345678"], createdAt: date, attempts: 3,
                          lastAttemptAt: date, ackedAt: date, failedAt: date))
    try roundTrip(Delivery(kind: .userMessage, sessionKey: "codex:/test#%1", content: "Hi", createdAt: date))
}

@Test func jsonLiteralsAndHelpers() throws {
    let json: JSONValue = ["null": nil, "bool": true, "int": 42, "float": 1.5, "text": "⚡", "array": [1, 2], "object": [:]]
    try roundTrip(json)
    #expect(json["null"] == .null)
    #expect(json["bool"] == .bool(true))
    #expect(json["array"]?[1] == 2)
    #expect(json["array"]?[-1] == nil)
    #expect(json["array"]?[2] == nil)
    #expect(json["missing"] == nil)
    #expect(JSONValue.null[0] == nil)
    #expect(JSONValue.null["key"] == nil)
    let input = InputSpec(placeholder: "Answer", multiline: true)
    #expect(try JSONValue.from(input).decode(InputSpec.self) == input)
    #expect(throws: (any Error).self) { try JSONValue.string("wrong").decode(InputSpec.self) }
    #expect(throws: (any Error).self) { try ZeusJSON.encoder().encode(JSONValue.number(.infinity)) }
}

@Test func fallbackAndGeneratedIDs() {
    #expect(AvatarState.idle.fallback == nil)
    #expect(AvatarState.working.fallback == .thinking)
    #expect(AvatarState.waiting.fallback == .alert)
    for state in AvatarState.allCases where ![.idle, .working, .waiting].contains(state) { #expect(state.fallback == .idle) }
    let card = Card(kind: .message, body: "Hello")
    let delivery = Delivery(kind: .userMessage, sessionKey: "other:/", content: "Hi")
    #expect(card.id.hasPrefix("c_") && card.id.count == 10)
    #expect(delivery.id.hasPrefix("d_") && delivery.id.count == 10)
    #expect(CardResponse(optionLabel: "Yes", text: "Thanks", device: .mac).summary == "Yes\nThanks")
    #expect(CardResponse(text: "", device: .mac).summary.isEmpty)
    #expect(CardResponse(text: "Hi", device: .mac).summary == "Hi")
}

@Test func isoDatesAndCamelCase() throws {
    let response = CardResponse(optionID: "yes", respondedAt: date, device: .mac)
    let json = try JSONValue.from(response)
    #expect(json["optionID"] == "yes")
    #expect(json["option_id"] == nil)
    #expect(json["respondedAt"] == "2023-11-14T22:13:20.125Z")
    let withoutFraction = Data(#"{"device":"mac","respondedAt":"2023-11-14T22:13:20Z"}"#.utf8)
    #expect(try ZeusJSON.decoder().decode(CardResponse.self, from: withoutFraction).respondedAt == Date(timeIntervalSince1970: 1_700_000_000))
    let invalid = Data(#"{"device":"mac","respondedAt":"yesterday"}"#.utf8)
    #expect(throws: (any Error).self) { try ZeusJSON.decoder().decode(CardResponse.self, from: invalid) }
}

@Test func skippedResponseIsExplicitAndOldSnapshotsDefaultToAnswered() throws {
    let old = Data(#"{"optionID":"yes","optionLabel":"Yes","text":"Keep it","device":"mac","respondedAt":"2023-11-14T22:13:20Z"}"#.utf8)
    let decoded = try ZeusJSON.decoder().decode(CardResponse.self, from: old)
    #expect(!decoded.skipped && decoded.summary == "Yes\nKeep it")
    #expect(!CardResponse(device: .mac).skipped)
    let skipped = CardResponse(respondedAt: date, device: .mac, skipped: true)
    try roundTrip(skipped)
    #expect(try JSONValue.from(skipped)["skipped"] == true)
    let card = Card(kind: .question, body: "Later?", createdAt: date, updatedAt: date, status: .answered, response: skipped)
    try roundTrip(card)
    let invalid = Data(#"{"skipped":"true","device":"mac","respondedAt":"2023-11-14T22:13:20Z"}"#.utf8)
    #expect(throws: (any Error).self) { try ZeusJSON.decoder().decode(CardResponse.self, from: invalid) }
}

@Test func standardPathsAndDirectoryCreation() throws {
    #expect(ZeusPaths.appSupport.path.hasSuffix("/Library/Application Support/Zeus"))
    #expect(ZeusPaths.bridgeSocket.lastPathComponent == "bridge.sock")
    #expect(ZeusPaths.deliveries.lastPathComponent == "deliveries.json")
    #expect(ZeusPaths.cards.lastPathComponent == "cards.json")
    #expect(ZeusPaths.userCharacters.lastPathComponent == "Characters")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try ZeusPaths.createDirectories(at: temporary)
    try ZeusPaths.createDirectories(at: temporary)
    #expect(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Characters").path))
}


@Test func budgetHoldSourceIsAdditiveAndLegacyRatingDecisionsDecode() throws {
    let old = CardMuteDecision(ratingID: "rating", kindLabel: "Updates", reason: "kind", engine: "exact", score: 1, threshold: 1, decidedAt: date)
    let encoded = try ZeusJSON.encoder().encode(old)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("source"))
    #expect(try ZeusJSON.decoder().decode(CardMuteDecision.self, from: encoded).source == nil)
    var budget = old; budget.source = .dailyBudget
    try roundTrip(budget)
    for kind in [Delivery.Kind.brief, .ruleTrigger] {
        try roundTrip(Delivery(kind: kind, sessionKey: "claude:/fixture#1.1", content: "Proactive request", createdAt: date))
    }
}
