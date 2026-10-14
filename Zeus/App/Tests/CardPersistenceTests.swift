import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct CardPersistenceTests {
    @Test func failedResponseWritePublishesNothingAndCanBeRetriedExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-response-write-\(UUID())")
        let url = root.appendingPathComponent("cards.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: url)
        let question = Card(kind: .question, body: "Continue?", input: InputSpec())
        store.add(question)
        let snapshot = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var deliveries = 0
        store.responseHandler = { card, response in
            deliveries += 1
            #expect(card.status == .answered && response.text == "Yes")
            #expect(CardStore(fileURL: url).card(id: question.id)?.response == response)
        }
        let reply = CardResponse(text: "Yes", respondedAt: Date(timeIntervalSince1970: 1730000000), device: .mac)
        #expect(!store.respond(id: question.id, response: reply))
        #expect(deliveries == 0)
        #expect(store.card(id: question.id) == question)
        #expect(store.seenIDs.isEmpty)
        #expect(store.persistenceError != nil)
        try FileManager.default.removeItem(at: url)
        try snapshot.write(to: url)
        #expect(CardStore(fileURL: url).card(id: question.id)?.status == .open)
        #expect(store.respond(id: question.id, response: reply))
        #expect(store.persistenceError == nil)
        #expect(store.seenIDs.contains(question.id))
        #expect(!store.respond(id: question.id, response: reply))
        #expect(deliveries == 1)
    }

    @Test(arguments: ["{invalid", "{\"version\":2,\"cards\":[],\"seenIDs\":[]}"])
    func corruptOrUnsupportedHistoryCannotRouteOrOverwriteAnAnswer(_ content: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-response-load-\(UUID())")
        let url = root.appendingPathComponent("cards.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data(content.utf8)
        try original.write(to: url)
        let store = CardStore(fileURL: url)
        let card = Card(kind: .question, body: "New question", options: [CardOption(id: "yes", label: "Yes")])
        store.add(card)
        var routes = 0
        store.responseHandler = { _, _ in routes += 1 }
        #expect(!store.respond(id: card.id, response: CardResponse(optionID: "yes", device: .mac)))
        #expect(routes == 0)
        #expect(store.card(id: card.id) == nil)
        #expect(store.card(id: card.id)?.response == nil)
        #expect(!store.seenIDs.contains(card.id))
        #expect(store.persistenceError != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func openCodeValidationRejectsCredentialsAndMatchesConnectorAvailability() throws {
        let suite = "zeus-url-credentials-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.backend = .opencode
        let connector = OpenCodeConnector(credentials: { nil })
        let session = ConnectedSession(id: UUID(), sessionKey: "opencode:/test", agent: .opencode, cwd: "/test", clientName: nil, supportsChannel: false, tmuxPane: nil, connectedAt: Date())
        for text in ["http://user:example@127.0.0.1:4096", "http://user@localhost:4096", "https://:example@localhost", "http://@localhost"] {
            settings.openCodeURLText = text
            #expect(settings.openCodeBaseURL == nil)
            #expect(settings.openCodeURLValidationMessage?.contains("Keychain") == true)
            #expect(!connector.canDeliver(to: session, bridge: nil, routing: settings))
        }
        settings.openCodeURLText = "https://localhost:4096/api"
        #expect(settings.openCodeURLValidationMessage == nil)
        #expect(connector.canDeliver(to: session, bridge: nil, routing: settings))
    }
}
