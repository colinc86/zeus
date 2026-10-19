import Foundation
import Testing

/// FX28: scratch suites keep their plist in a scratch folder, never in ~/Library/Preferences.
struct TestDefaultsTests {
    @Test func scratchSuiteStaysOutOfUserPreferences() throws {
        let suite = TestDefaults.suite("zeus-fx28")
        #expect(suite.hasPrefix(TestDefaults.folder.path + "/zeus-fx28-"))
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("value", forKey: "fx28")
        #expect(defaults.synchronize())
        #expect(UserDefaults(suiteName: suite)?.string(forKey: "fx28") == "value")
        #expect(FileManager.default.fileExists(atPath: suite + ".plist"))
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()

        let name = URL(fileURLWithPath: suite).lastPathComponent + ".plist"
        let preferences = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
        #expect(!FileManager.default.fileExists(atPath: preferences.appendingPathComponent(name).path))
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }
}
