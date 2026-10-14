import Foundation

/// Reads the shipped app's version beside its embedded helper, independent of cwd
/// and the running Zeus build. An unbundled development helper identifies itself honestly.
public enum MCPReleaseVersion {
    /// Version of this helper's containing Zeus.app, or `development` when unbundled.
    public static var current: String {
        resolve(executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    /// Resolves only the standard .app/Contents/MacOS layout; never searches user config.
    public static func resolve(executableURL: URL) -> String {
        let executable = executableURL.resolvingSymlinksInPath()
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "development" }
        return version
    }
}
