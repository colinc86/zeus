import Foundation

/// Scratch `UserDefaults` suites that never touch `~/Library/Preferences`.
///
/// A plain suite name such as `"zeus-x-<UUID>"` is stored by cfprefsd in the user's real
/// `~/Library/Preferences`, and `removePersistentDomain(forName:)` leaves an empty plist there
/// for good. cfprefsd ignores `HOME` and `CFFIXED_USER_HOME`, so a disposable home does not help.
/// A suite name that is an absolute path makes CFPreferences keep `<path>.plist` at that path,
/// so every suite here lives in a scratch folder instead. Seed such a suite with `set(_:forKey:)`:
/// values from `setPersistentDomain(_:forName:)` on a path domain survive `removeObject(forKey:)`.
enum TestDefaults {
    /// The folder that holds scratch suites. `scripts/test.sh` points `ZEUS_TEST_DEFAULTS_DIR`
    /// (via `TEST_RUNNER_ZEUS_TEST_DEFAULTS_DIR`) at a folder it deletes after the run.
    static let folder: URL = {
        if let path = ProcessInfo.processInfo.environment["ZEUS_TEST_DEFAULTS_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("zeus-test-defaults", isDirectory: true)
    }()

    /// A fresh suite name, `<folder>/<prefix>-<UUID>`, for `UserDefaults(suiteName:)`.
    static func suite(_ prefix: String) -> String {
        folder.appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
    }
}
