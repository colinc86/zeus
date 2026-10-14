import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private actor SessionListTransport: ConnectorHTTPTransport {
    var requests: [URLRequest] = []
    var pending: [CheckedContinuation<ConnectorHTTPResult, any Error>] = []
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResult {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(_ index: Int, status: Int = 200, json: String) {
        pending[index].resume(returning: .init(status: status, body: Data(json.utf8)))
    }
    func awaitRequests(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }
}

@MainActor struct OpenCodeSessionPickerTests {
    private func session(_ key: String, cwd: String = "/work/Zeus") -> ConnectedSession {
        .init(id: UUID(), sessionKey: "opencode:\(cwd)#\(key)", agent: .opencode, cwd: cwd, clientName: nil,
              supportsChannel: false, tmuxPane: nil, connectedAt: Date())
    }
    @Test(arguments: ["Assistant", ""])
    func duplicateNativeLabelsStayDistinctAndStableAcrossReorderedRefreshes(title: String) {
        let a = OpenCodeNativeSession(id: "ses_first_shared_tail", title: title, directory: "/work/project")
        let b = OpenCodeNativeSession(id: "ses_second_shared_tail", title: title, directory: "/work/project")
        let other = OpenCodeNativeSession(id: "ses_other", title: "Unique", directory: "/work/project")
        let labels = OpenCodeNativeSession.labels(for: [a, b, other])
        #expect(labels[a.id] != labels[b.id])
        #expect(labels == OpenCodeNativeSession.labels(for: [other, b, a]))
        #expect(labels[other.id] == other.label)
        #expect(a.selectionDetail.contains(a.id) && b.selectionDetail.contains(b.id))
        #expect(OpenCodeNativeSession.selectedLabel(a.id, sessions: [b, a]) == labels[a.id])
        #expect(OpenCodeNativeSession.selectedLabel("ses_missing", sessions: [b, a]).contains("ses_missing"))
        #expect(OpenCodeNativeSession.selectedLabel(nil, sessions: [b, a]) == "Choose a conversation")
    }

    @Test func shortAndLongIDsSharingASuffixStillHaveDifferentLabels() {
        let a = OpenCodeNativeSession(id: "ses_A", title: "Assistant", directory: "/work/project")
        let b = OpenCodeNativeSession(id: "ses_A_ses_A", title: "Assistant", directory: "/work/project")
        let labels = OpenCodeNativeSession.labels(for: [a, b])
        #expect(labels[a.id] != labels[b.id])
    }

    @Test func mappingIsExplicitScopedPersistentAndGroupsOnlyUnmappedFolders() throws {
        let suite = "zeus-native-selection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let a = session("1.1"), b = session("2.2"), c = session("3.3", cwd: "/other")
        #expect(settings.openCodeSessionID(for: a.sessionKey) == nil)
        #expect(settings.assistantCandidates([b,a,c]).map(\.sessionKey) == [b.sessionKey,c.sessionKey])
        settings.assistantSessionKey = a.sessionKey
        #expect(settings.assistantCandidates([b,a,c]).map(\.sessionKey) == [a.sessionKey,c.sessionKey])
        settings.setOpenCodeSessionID("ses_native_a", for: a.sessionKey)
        #expect(settings.assistantCandidates([b,a,c]).count == 3)
        settings.setOpenCodeSessionID("../bad", for: a.sessionKey)
        #expect(settings.openCodeSessionID(for: a.sessionKey) == "ses_native_a")
        #expect(settings.openCodeSessionID(for: b.sessionKey) == nil)
        #expect(AppSettings(defaults: defaults, userDirectory: nil).openCodeSessionID(for: a.sessionKey) == "ses_native_a")
        settings.setOpenCodeSessionID(nil, for: a.sessionKey)
        #expect(settings.openCodeSessionID(for: a.sessionKey) == nil)
    }
    @Test func listingScopesTheRequestAndAcceptsOnlyValidMatchingFolderSessions() async throws {
        let transport = SessionListTransport()
        let model = OpenCodeSessionDiscovery(transport: transport)
        let task = Task { await model.refresh(baseURL: URL(string: "http://localhost:4096/api"), directory: "/work/Zeus & UI", password: "fixture-password") }
        await transport.awaitRequests(1)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET" && request.url?.path == "/api/session")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/work/Zeus & UI")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:fixture-password".utf8).base64EncodedString())
        await transport.complete(0, json: """
        [{"id":"ses_b","title":"Beta","directory":"/work/Zeus & UI"},
         {"id":"ses_a","title":"Alpha","directory":"/work/Zeus & UI"},
         {"id":"ses_b","title":"Duplicate","directory":"/work/Zeus & UI"},
         {"id":"ses_other","title":"Other","directory":"/other"},
         {"id":"ses/invalid","title":"Invalid","directory":"/work/Zeus & UI"}]
        """)
        await task.value
        #expect(model.sessions.map(\.id) == ["ses_a","ses_b"])
        #expect(model.sessions.first?.label == "Alpha · /work/Zeus & UI")
        #expect(!model.isLoading && model.error == nil)
    }
    @Test func staleResponsesCannotReplaceTheNewConnectionAndAuthenticationErrorsAreActionable() async {
        let transport = SessionListTransport()
        let discovery = OpenCodeSessionDiscovery(transport: transport)
        let first = Task { await discovery.refresh(baseURL: URL(string: "http://localhost:4096"), directory: "/old", password: nil) }
        await transport.awaitRequests(1)
        let second = Task { await discovery.refresh(baseURL: URL(string: "http://localhost:4096"), directory: "/new", password: nil) }
        await transport.awaitRequests(2)
        await transport.complete(1, status: 401, json: "{}")
        await second.value
        #expect(discovery.error?.contains("Keychain") == true)
        await transport.complete(0, json: "[{\"id\":\"ses_old\",\"title\":\"Old\",\"directory\":\"/old\"}]")
        await first.value
        #expect(discovery.sessions.isEmpty && discovery.error?.contains("Keychain") == true && !discovery.isLoading)
    }
}
