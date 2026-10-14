import Foundation

/// A native session is meaningful only on the server where the user selected it.
/// Settings persist this value atomically when selecting a session, never on URL edits.
struct OpenCodeDestination: Codable, Equatable, Sendable {
    let sessionID: String
    let endpoint: URL

    init?(sessionID: String, endpoint: URL) {
        guard sessionID.hasPrefix("ses"), sessionID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
              let endpoint = Self.canonicalEndpoint(endpoint) else { return nil }
        self.sessionID = sessionID; self.endpoint = endpoint
    }

    private enum CodingKeys: String, CodingKey { case sessionID, endpoint }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .sessionID)
        let url = try values.decode(URL.self, forKey: .endpoint)
        guard let value = Self(sessionID: id, endpoint: url) else {
            throw DecodingError.dataCorruptedError(forKey: .endpoint, in: values, debugDescription: "Invalid native OpenCode destination")
        }
        self = value
    }

    /// Canonical comparison preserves proxy paths and rejects credential/query-bearing URLs.
    static func canonicalEndpoint(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme; parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        return parts.url
    }
}

/// Optional source-compatible Settings capability. Old ID-only mappings are unverified;
/// they must be chosen again rather than rebound to the current global server URL.
@MainActor
protocol OpenCodeDestinationRouting {
    func openCodeDestination(for sessionKey: String) -> OpenCodeDestination?
}
