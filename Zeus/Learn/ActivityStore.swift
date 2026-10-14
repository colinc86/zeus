import Foundation

/// One raw level-1 event (CONTRACT §13): which app is frontmost, launches and quits, lock/sleep, idle periods and
/// display count. Never keystrokes, clipboard, window titles, URLs, file names, screenshots, audio or location.
struct ActivityEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case activate, launch, quit, lock, unlock, sleep, wake
        /// No input for 5 minutes or more; `t` is the last input.
        case idle
        /// Input again after an idle period; `t` is the first input.
        case active
        /// Time in an excluded app: `seconds` only, never a bundle id or name.
        case `private`
        case displays
    }
    var t: Date
    var kind: Kind
    /// Bundle id, for app events.
    var app: String?
    var name: String?
    var seconds: Double?
    var displays: Int?

    init(t: Date, kind: Kind, app: String? = nil, name: String? = nil, seconds: Double? = nil, displays: Int? = nil) {
        self.t = t; self.kind = kind; self.app = app; self.name = name; self.seconds = seconds; self.displays = displays
    }

    /// The user is at the Mac at `t`.
    var showsPresence: Bool { [.activate, .active, .unlock, .wake, .private].contains(kind) }
    /// The user left at `t`.
    var startsAbsence: Bool { [.idle, .lock, .sleep].contains(kind) }
    var appName: String { name ?? app ?? "an app" }

    /// "Switched to Xcode", as Settings › Privacy lists today's events.
    var plainDescription: String {
        switch kind {
        case .activate: "Switched to \(appName)"
        case .launch: "Opened \(appName)"
        case .quit: "Quit \(appName)"
        case .lock: "Locked the screen"
        case .unlock: "Unlocked the screen"
        case .sleep: "Mac went to sleep"
        case .wake: "Mac woke up"
        case .idle: "Away: no input for 5 min or more"
        case .active: "Back"
        case .private: "A private app for \(LearningSummarizer.duration(seconds ?? 0))"
        case .displays: (displays ?? 1) == 1 ? "1 display" : "\(displays ?? 1) displays"
        }
    }
}

/// Raw events on this Mac: one JSON-lines file per day in `Application Support/Zeus/Activity/`, readable only by the
/// user (0600, folder 0700). Not synced anywhere. Tests pass their own `root`.
@MainActor
final class ActivityStore {
    let root: URL
    let calendar: Calendar
    private static let filePermissions = 0o600
    private static let folderPermissions = 0o700

    init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    /// `2026-10-13`, in the store's calendar.
    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func fileURL(for day: Date) -> URL { root.appendingPathComponent(dayKey(day) + ".jsonl") }

    func append(_ event: ActivityEvent) throws {
        try ensureFolder()
        let url = fileURL(for: event.t)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: Self.filePermissions]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.encoder.encode(event) + Data("\n".utf8))
    }

    /// The day's events in time order. Lines that don't parse are skipped.
    func events(on day: Date) -> [ActivityEvent] {
        guard let text = try? String(contentsOf: fileURL(for: day), encoding: .utf8) else { return [] }
        let events = text.split(separator: "\n").compactMap { try? Self.decoder.decode(ActivityEvent.self, from: Data($0.utf8)) }
        return events.enumerated().sorted { $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t }.map(\.element)
    }

    /// Days with a raw file, oldest first, as the start of each day.
    func recordedDays() -> [Date] {
        rawFiles().compactMap(\.day).sorted()
    }

    /// Deletes raw files older than `keepingDays` days. Learnings are pruned by `LearningsStore`.
    func prune(now: Date, keepingDays: Int) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: calendar.startOfDay(for: now)) else { return }
        for file in rawFiles() where file.day.map({ $0 < cutoff }) ?? false {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Removes every file in the Activity folder.
    func deleteEverything() {
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes a private file (0600) in the folder, replacing it atomically.
    func writePrivate(_ data: Data, named name: String) throws {
        try ensureFolder()
        let url = root.appendingPathComponent(name)
        let temp = root.appendingPathComponent("." + name + ".tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: Self.filePermissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
    func read(named name: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(name)) }

    private func ensureFolder() throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: Self.folderPermissions])
    }

    private func rawFiles() -> [(url: URL, day: Date?)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.map { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return (url, nil) }
            return (url, calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])))
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
