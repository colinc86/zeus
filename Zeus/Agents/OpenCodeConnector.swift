import Foundation
import CryptoKit
import ZeusLink
import ZeusProtocol

/// HTTP result separated from URLSession so tests can record exact requests.
struct ConnectorHTTPResult: Sendable {
    var status: Int
    var body: Data
}

/// Injectable request/response boundary. Implementations must honor cancellation.
protocol ConnectorHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResult
}

/// Ephemeral HTTP transport with finite deadlines and no cached credentials or cookies.
struct URLSessionConnectorTransport: ConnectorHTTPTransport {
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 10
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResult {
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectorError.invalidHTTPResult }
        return .init(status: response.statusCode, body: body)
    }
}

/// Optional authentication value. Defaults mirror OpenCode's own server environment.
struct OpenCodeCredentials: Sendable, Equatable {
    var username: String = "opencode"
    var password: String
    static func environment() -> Self? {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["OPENCODE_SERVER_PASSWORD"], !password.isEmpty else { return nil }
        return .init(username: env["OPENCODE_SERVER_USERNAME"] ?? "opencode", password: password)
    }
}

/// Targets one native OpenCode session without mutating/submitting the TUI draft.
/// Stable message/part IDs and read-before-send recover uncertain HTTP receipts.
@MainActor
struct OpenCodeConnector: DeliveryConnector {
    private let transport: any ConnectorHTTPTransport
    private let gate = ConnectorSendGate()
    private let credentials: @MainActor () -> OpenCodeCredentials?
    init(transport: any ConnectorHTTPTransport = URLSessionConnectorTransport(),
         credentials: @escaping @MainActor () -> OpenCodeCredentials? = OpenCodeCredentials.environment) {
        self.transport = transport; self.credentials = credentials
    }
    private func valid(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }
    func canDeliver(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool {
        routing.deliveryMethod == .opencode && session.agent == .opencode && valid(routing.openCodeBaseURL)
    }
    /// Deterministic native identities survive app/helper restarts and lost HTTP results.
    static func nativeID(prefix: String, delivery: Delivery, sessionID: String) -> String {
        let milliseconds = delivery.meta["opencode_created_ms"].flatMap(UInt64.init) ?? UInt64(max(0, delivery.createdAt.timeIntervalSince1970 * 1000))
        let time = String(format: "%012llx", (milliseconds << 12) & 0xffffffffffff)
        let hash = SHA256.hash(data: Data((delivery.id + ":" + sessionID).utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + "_" + time + hash.prefix(14)
    }
    func deliver(_ delivery: Delivery, to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) async throws {
        guard let current = routing.openCodeBaseURL.flatMap(OpenCodeDestination.canonicalEndpoint) else { throw ConnectorError.invalidURL }
        let pinned = delivery.meta["opencode_destination_validated"] == "true"
        let selection: OpenCodeDestination?
        if pinned {
            selection = delivery.meta["opencode_session_id"].flatMap { id in
                delivery.meta["opencode_endpoint"].flatMap(URL.init(string:)).flatMap { OpenCodeDestination(sessionID: id, endpoint: $0) }
            }
        } else {
            selection = (routing as? any OpenCodeDestinationRouting)?.openCodeDestination(for: session.sessionKey)
        }
        guard session.agent == .opencode, let selection else {
            throw pinned ? ConnectorError.unverifiedOpenCodeDestination : ConnectorError.missingOpenCodeSession
        }
        guard selection.endpoint == current else { throw ConnectorError.mismatchedOpenCodeEndpoint }
        let base = selection.endpoint, id = selection.sessionID
        let destination = base.absoluteString + ":" + id
        try await gate.acquire(destination)
        defer { gate.release(destination) }
        let fallback = credentials()
        let auth = routing.openCodeServerPassword.map { OpenCodeCredentials(username: fallback?.username ?? "opencode", password: $0) } ?? fallback
        if let auth, auth.username.contains(":") { throw ConnectorError.invalidCredentials }
        func request(_ path: [String], method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
            let url = path.reduce(base) { $0.appendingPathComponent($1) }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ConnectorError.invalidURL }
            var query = components.queryItems ?? []; query.removeAll { $0.name == "directory" }
            query.append(.init(name: "directory", value: session.cwd)); components.queryItems = query
            guard let scoped = components.url else { throw ConnectorError.invalidURL }
            var result = URLRequest(url: scoped, timeoutInterval: 5)
            result.httpMethod = method
            result.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { result.httpBody = try ZeusJSON.encoder().encode(body); result.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let auth, !auth.password.isEmpty { result.setValue("Basic " + Data((auth.username + ":" + auth.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
            return result
        }
        // Validate the selected native session, not merely the directory query's scope.
        let info = try await transport.send(request(["session", id]))
        guard info.status == 200 else { throw ConnectorError.httpStatus(info.status) }
        let json = try ZeusJSON.decoder().decode(JSONValue.self, from: info.body)
        guard json["id"] == .string(id), json["directory"] == .string(session.cwd) else { throw ConnectorError.mismatchedOpenCodeSession }
        try (routing as? DeliveryRoutingContext)?.confirmOpenCodeDestination?(selection)
        let messageID = Self.nativeID(prefix: "msg", delivery: delivery, sessionID: id)
        let partID = Self.nativeID(prefix: "prt", delivery: delivery, sessionID: id)
        let text = AgentInjectionText.format(delivery)
        func alreadySaved() async throws -> Bool {
            let response = try await transport.send(request(["session", id, "message", messageID]))
            if response.status == 404 { return false }
            guard response.status == 200 else { throw ConnectorError.httpStatus(response.status) }
            let value = try ZeusJSON.decoder().decode(JSONValue.self, from: response.body)
            guard value["info"]?["id"] == .string(messageID), value["info"]?["role"] == "user",
                  case .array(let parts) = value["parts"] else { throw ConnectorError.invalidHTTPResult }
            guard let part = parts.first(where: { $0["id"] == .string(partID) }) else {
                // OpenCode saves message and parts separately. A crash between them
                // is repaired with the same identities, not a second draft append.
                return false
            }
            guard part["type"] == "text", part["text"] == .string(text) else { throw ConnectorError.invalidHTTPResult }
            return true
        }
        if try await alreadySaved() { return }
        let body: JSONValue = ["messageID": .string(messageID), "parts": [["id": .string(partID), "type": "text", "text": .string(text)]]]
        let response: ConnectorHTTPResult
        do { response = try await transport.send(request(["session", id, "prompt_async"], method: "POST", body: body)) }
        catch {
            // The server may have saved the prompt before the HTTP connection failed.
            if !Task.isCancelled, (try? await alreadySaved()) == true { return }
            throw error
        }
        guard response.status == 204 else {
            if (try? await alreadySaved()) == true { return }
            throw ConnectorError.httpStatus(response.status)
        }
        // Acceptance starts a server task; require durable message/part visibility
        // before claiming transport delivery. Retry reads first and never appends a draft.
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if try await alreadySaved() { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw ConnectorError.invalidHTTPResult
    }
}
