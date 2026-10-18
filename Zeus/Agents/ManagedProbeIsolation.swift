import Darwin
import Foundation

/// A disposable environment must not regain the account's folders through preferences or Foundation defaults.
enum ManagedProbeIsolation {
    private static let accountHome: String = {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }()
    static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(url.path, nil) {
                defer { free(resolved) }
                let base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                return missing.reversed().reduce(base) { $0.appendingPathComponent($1) }.path
            }
            guard url.path != "/" else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            missing.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
    }
    static func contains(_ path: String, in home: String) -> Bool {
        let path = canonical(path), home = canonical(home)
        return path == home || path.hasPrefix(home + "/")
    }
    static func requiresBoundary(_ environment: [String: String], isolatedSocket: String? = nil) -> Bool {
        if isolatedSocket != nil || NSClassFromString("XCTestCase") != nil { return true }
        if environment.keys.contains(where: { $0.hasPrefix("XCTest") || ($0.hasPrefix("ZEUS_") && ($0.contains("PROBE") || $0.contains("LIVE") || $0.contains("TEST"))) }) { return true }
        return [environment["HOME"], environment["CFFIXED_USER_HOME"]].compactMap { $0 }.contains { canonical($0) != canonical(accountHome) }
    }
    static func home(_ environment: [String: String]) throws -> String {
        guard let home = environment["HOME"], home.hasPrefix("/"), !home.contains("\0"),
              canonical(home) != "/", canonical(home) != canonical(accountHome) else {
            throw ManagedSessionError.command("A probe or test requires an explicit disposable HOME.")
        }
        if let fixed = environment["CFFIXED_USER_HOME"], canonical(fixed) != canonical(home) {
            throw ManagedSessionError.command("The probe's HOME and CFFIXED_USER_HOME disagree.")
        }
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"] {
            if let path = environment[key], !path.isEmpty, (!path.hasPrefix("/") || path.contains("\0") || !contains(path, in: home)) {
                throw ManagedSessionError.command("A probe or test cannot use agent configuration outside its disposable HOME.")
            }
        }
        return canonical(home)
    }
    static func validate(folder: String, environment: [String: String], isolatedSocket: String? = nil) throws {
        guard requiresBoundary(environment, isolatedSocket: isolatedSocket) else { return }
        let home = try home(environment)
        guard folder.hasPrefix("/"), !folder.contains("\0"), contains(folder, in: home) else {
            throw ManagedSessionError.command("A probe or test cannot start an assistant outside its disposable HOME.")
        }
    }
    static func validateSocket(_ socket: String?, environment: [String: String], isolatedSocket: String?) throws {
        guard requiresBoundary(environment, isolatedSocket: isolatedSocket) else { return }
        let home = try home(environment)
        if let isolatedSocket, let socket, canonical(socket) == canonical(isolatedSocket),
           !canonical(socket).hasPrefix("/private/tmp/tmux-") { return }
        if let temporary = environment["TMUX_TMPDIR"], contains(temporary, in: home),
           socket.map({ contains($0, in: temporary) }) ?? true { return }
        throw ManagedSessionError.command("A probe or test requires its own private tmux socket.")
    }
}
