import Foundation
import Testing
@testable import Zeus

@MainActor
@Suite(.serialized)
struct PerformanceProbeTests {
    @Test func rejectsMissingMismatchedOrEscapedHomes() throws {
        let home = "/private/tmp/zperf_" + UUID().uuidString
        let valid = ["ZEUS_PERF_PROBE": "1", "HOME": home, "CFFIXED_USER_HOME": home, "TMUX_TMPDIR": home + "/tmux"]
        #expect(try PerformanceProbe.validatedHome(valid).path == home)
        for key in valid.keys {
            var invalid = valid; invalid.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try PerformanceProbe.validatedHome(invalid) }
        }
        for (key, value) in [("HOME", "/"), ("CFFIXED_USER_HOME", "/private/tmp/other"),
                             ("ZEUS_PERF_PROBE", "0"), ("CLAUDE_CONFIG_DIR", "/outside/config")] {
            var invalid = valid; invalid[key] = value
            #expect(throws: (any Error).self) { try PerformanceProbe.validatedHome(invalid) }
        }
    }

    @Test func isolatedShellUsesNoCredentialsAndNeverStartsCaptureOrManagedAgent() throws {
        let root = URL(fileURLWithPath: "/private/tmp/zperf_" + UUID().uuidString)
        defer { PerformanceProbe.cleanup(); try? FileManager.default.removeItem(at: root) }
        let env = ["ZEUS_PERF_PROBE": "1", "HOME": root.path, "CFFIXED_USER_HOME": root.path,
                   "TMUX_TMPDIR": root.appendingPathComponent("tmux").path]
        let preferences = root.appendingPathComponent("Library/Preferences/com.colinc86.Zeus.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enabled = ObservationPolicy(enabled: true, consented: true)
        let values: [String: Any] = ["learn.enabled": true,
            "learn.levelPolicies": try JSONEncoder().encode([2: enabled, 3: enabled, 4: enabled]),
            "learn.rawLevels": [3, 4]]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: preferences)
        let shell = PerformanceProbe.makeShell(environment: env)
        for level in 1...4 {
            #expect(!shell.learning.policies.policy(level).enabled)
            #expect(!shell.learning.policies.policy(level).consented)
            #expect(!shell.learning.policies.rawAllowed(level))
        }
        #expect(shell.learningServices?.source.isLocked == true)
        #expect(shell.settings.managedSession?.enabled == false)
        #expect(!shell.learn.settings.enabled)
        #expect(shell.learningServices?.source.isTrusted == false)
        #expect(shell.learningServices?.source.application == nil)
        #expect(shell.learningServices?.journal is EncryptedJournalStore)
        #expect(try PerformanceProbe.makeRatings(environment: env).state.ratings.isEmpty)
        #expect(throws: (any Error).self) { try PerformanceProbe.makeRatings(environment: [:]) }
    }
}
