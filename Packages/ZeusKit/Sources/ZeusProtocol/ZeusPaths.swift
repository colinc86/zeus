import Foundation

/// Standard user-local Zeus storage locations; independent of AppKit.
public enum ZeusPaths {
    /// Root directory for local state and bridge socket.
    public static var appSupport: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support/Zeus", isDirectory: true) }
    /// Socket listened to by the Mac app.
    public static var bridgeSocket: URL { appSupport.appendingPathComponent("bridge.sock") }
    /// Persisted delivery ledger.
    public static var deliveries: URL { appSupport.appendingPathComponent("deliveries.json") }
    /// Persisted cards.
    public static var cards: URL { appSupport.appendingPathComponent("cards.json") }
    /// User-provided character definitions.
    public static var userCharacters: URL { appSupport.appendingPathComponent("Characters", isDirectory: true) }
    /// User-provided color themes (docs/design/THEME_FORMAT.md).
    public static var userThemes: URL { appSupport.appendingPathComponent("Themes", isDirectory: true) }
    /// "Learn from me" raw events and summaries, readable only by the user (CONTRACT §13).
    public static var activity: URL { appSupport.appendingPathComponent("Activity", isDirectory: true) }
    /// Creates the support, character and theme directories. A custom root supports tests and migrations.
    public static func createDirectories(at root: URL = appSupport) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Characters", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Themes", isDirectory: true), withIntermediateDirectories: true)
    }
}
