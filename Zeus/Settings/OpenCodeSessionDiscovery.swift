import Foundation
import Observation

/// Native sessions are explicitly chosen; listing never changes routing preferences.
struct OpenCodeNativeSession: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let directory: String
    var label: String { "\(title.isEmpty ? "Untitled session" : title) · \(directory)" }
    var selectionDetail: String { "\(directory) · \(id)" }

    /// Duplicate titles/folders need a native identity hint. Suffixes stay stable when
    /// the server changes list order and expand until every displayed choice is distinct.
    static func labels(for sessions: [Self]) -> [String: String] {
        var result: [String: String] = [:]
        for (base, group) in Dictionary(grouping: sessions, by: \.label) {
            if group.count == 1 { if let item = group.first { result[item.id] = base }; continue }
            let maximum = group.map { $0.id.count }.max() ?? 6
            var length = min(6, maximum)
            func token(_ item: Self) -> String { (item.id.count > length ? "…" : "") + item.id.suffix(length) }
            while length < maximum && Set(group.map(token)).count < group.count { length += 1 }
            for item in group { result[item.id] = base + " · " + token(item) }
        }
        return result
    }
    static func selectedLabel(_ id: String?, sessions: [Self]) -> String {
        guard let id else { return "Choose a conversation" }
        return labels(for: sessions)[id] ?? "Saved conversation · \(id) (not listed)"
    }
    static func validID(_ id: String) -> Bool {
        id.hasPrefix("ses") && id.count > 3 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }
}

@MainActor @Observable
final class OpenCodeSessionDiscovery {
    private(set) var sessions: [OpenCodeNativeSession] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var listedBaseURL: URL?
    @ObservationIgnored private let transport: any ConnectorHTTPTransport
    @ObservationIgnored private var generation = 0
    init(transport: any ConnectorHTTPTransport = URLSessionConnectorTransport()) { self.transport = transport }

    func refresh(baseURL: URL?, directory: String?, password: String?) async {
        generation += 1
        let requestGeneration = generation
        sessions = []; error = nil; listedBaseURL = nil; isLoading = false
        guard let baseURL, let directory else { return }
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              var components = URLComponents(url: baseURL.appendingPathComponent("session"), resolvingAgainstBaseURL: false) else {
            error = "Enter a valid OpenCode server URL first."; return
        }
        components.queryItems = [.init(name: "directory", value: directory)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let password, !password.isEmpty {
            request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            let result = try await transport.send(request)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            guard result.status == 200 else {
                error = result.status == 401 || result.status == 403
                    ? "OpenCode didn't accept the password. Check the server password saved in Keychain, then refresh."
                    : "OpenCode couldn't list its conversations (error \(result.status)). Refresh, or let it check in."
                return
            }
            let listed = try JSONDecoder().decode([OpenCodeNativeSession].self, from: result.body)
            listedBaseURL = baseURL
            var seen: Set<String> = []
            sessions = listed.filter { $0.directory == directory && OpenCodeNativeSession.validID($0.id) && seen.insert($0.id).inserted }
                .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch is CancellationError { }
        catch {
            guard requestGeneration == generation else { return }
            self.error = "Couldn't reach OpenCode. Check the server URL and that OpenCode is running, then refresh, or let it check in."
        }
    }
}
