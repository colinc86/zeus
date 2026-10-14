import Foundation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor private struct DestinationCredentials: OpenCodePasswordStoring {
    // Connector delivery may read this in-memory stub; it never accesses Keychain.
    func read() -> String? { nil }
    func save(_ password: String?) { Issue.record("Destination selection must not write credentials") }
}

@MainActor struct AppSettingsOpenCodeDestinationTests {
    private func settings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, userDirectory: nil, passwordStore: DestinationCredentials())
    }
    private let key = "opencode:/assistant#101.1000"

    @Test func selectionSavesIDAndCanonicalEndpointTogetherAndURLEditsLeaveBytesUntouched() throws {
        let suite = "zeus-destination-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = settings(defaults)
        model.openCodeURLText = "HTTP://SERVER-A.TEST:80/proxy/"
        #expect(model.setOpenCodeSessionID("ses_shared", for: key))
        let routing: any OpenCodeDestinationRouting = model
        let destination = try #require(routing.openCodeDestination(for: key))
        #expect(destination.sessionID == "ses_shared" && destination.endpoint.absoluteString == "http://server-a.test/proxy")
        let data = try #require(defaults.data(forKey: "agent.openCodeDestinations"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require((object["destinations"] as? [String: [String: String]])?[key])
        #expect(stored["sessionID"] == destination.sessionID && stored["endpoint"] == destination.endpoint.absoluteString)
        model.openCodeURLText = "http://server-b.test/proxy"
        #expect(defaults.data(forKey: "agent.openCodeDestinations") == data)
        let reload = settings(defaults)
        #expect(reload.openCodeDestination(for: key) == destination)
        #expect(reload.openCodeSelectionNotice(for: key) == ZeusRuntimeCopy.OpenCode.otherServerNotice(destination.endpoint.absoluteString))
        reload.openCodeURLText = "http://SERVER-A.TEST:80/proxy///"
        #expect(reload.openCodeSelectionNotice(for: key) == nil)
        #expect(defaults.data(forKey: "agent.openCodeDestinations") == data)
    }

    @Test func legacySelectionsRequireExplicitReselectionAndClearCannotResurrectThem() throws {
        let suite = "zeus-destination-legacy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let other = "opencode:/other#102.1000"
        defaults.set([key: "ses_old", other: "ses_other"], forKey: "agent.openCodeSelections")
        let model = settings(defaults)
        #expect(model.openCodeDestination(for: key) == nil && model.openCodeSessionID(for: key) == nil)
        #expect(model.savedOpenCodeSessionID(for: key) == "ses_old")
        #expect(model.openCodeSelectionNotice(for: key) == ZeusRuntimeCopy.OpenCode.chooseAgainNotice)
        model.openCodeURLText = "http://server-b.test:4096"
        #expect(model.openCodeDestination(for: key) == nil)
        #expect(model.setOpenCodeSessionID("ses_old", for: key))
        let reload = settings(defaults)
        #expect(reload.openCodeDestination(for: key)?.endpoint.host == "server-b.test")
        #expect(reload.openCodeSelectionNotice(for: key) == nil)
        #expect(reload.openCodeDestination(for: other) == nil && reload.savedOpenCodeSessionID(for: other) == "ses_other")
        #expect(reload.setOpenCodeSessionID(nil, for: key) && reload.setOpenCodeSessionID(nil, for: other))
        let cleared = settings(defaults)
        #expect(cleared.savedOpenCodeSessionID(for: key) == nil && cleared.savedOpenCodeSessionID(for: other) == nil)
        #expect(cleared.openCodeSelectionNotice(for: key) == nil)
    }

    @Test func invalidSelectionOrURLCannotPartiallyReplaceARecordedDestination() throws {
        let suite = "zeus-destination-invalid-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = settings(defaults)
        #expect(model.setOpenCodeSessionID("ses_valid", for: key))
        let data = try #require(defaults.data(forKey: "agent.openCodeDestinations"))
        #expect(!model.setOpenCodeSessionID("../bad", for: key))
        #expect(!model.setOpenCodeSessionID("ses_valid", for: "claude:/assistant#101.1000"))
        for url in ["http://user:secret@server.test", "http://server.test?secret=value", "http://server.test#fragment", "file:///fixture"] {
            model.openCodeURLText = url
            #expect(!model.setOpenCodeSessionID("ses_replacement", for: key))
            #expect(defaults.data(forKey: "agent.openCodeDestinations") == data)
            #expect(model.openCodeSessionID(for: key) == "ses_valid")
        }
    }

    @Test func actualSettingsCapabilityBlocksChangedEndpointUntilTheSameIDIsChosenAgain() async throws {
        let suite = "zeus-destination-connector-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = settings(defaults), http = NativeOpenCodeHTTP()
        let connector = OpenCodeConnector(transport: http, credentials: { nil })
        let session = connectorSession(agent: .opencode)
        let native = OpenCodeNativeSession(id: "ses_shared", title: "Assistant", directory: session.cwd)
        let a = try #require(URL(string: "http://server-a.test:4096"))
        let b = try #require(URL(string: "http://server-b.test:4096"))
        model.deliveryMethod = .opencode; model.openCodeURLText = a.absoluteString
        #expect(OpenCodeSessionPicker.select(native.id, for: session.sessionKey, sessions: [native], endpoint: a, settings: model))
        model.openCodeURLText = b.absoluteString
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Only the selected server")
        await #expect(throws: ConnectorError.mismatchedOpenCodeEndpoint) {
            try await connector.deliver(delivery, to: session, bridge: nil, routing: model)
        }
        #expect(await http.calls.isEmpty)
        #expect(!OpenCodeSessionPicker.select(native.id, for: session.sessionKey, sessions: [native], endpoint: a, settings: model))
        #expect(model.openCodeSelectionNotice(for: session.sessionKey) != nil)
        #expect(OpenCodeSessionPicker.select(native.id, for: session.sessionKey, sessions: [native], endpoint: b, settings: model))
        #expect(model.openCodeSelectionNotice(for: session.sessionKey) == nil)
        let reload = settings(defaults)
        try await connector.deliver(delivery, to: session, bridge: nil, routing: reload)
        let calls = await http.calls
        #expect(calls.allSatisfy { $0.url?.host == "server-b.test" })
        #expect(calls.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(reload.openCodeDestination(for: session.sessionKey)?.endpoint == b)
    }
}
