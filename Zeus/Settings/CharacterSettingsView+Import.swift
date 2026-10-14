import CoreServices
import Foundation
import Observation
import ZeusSprites

/// Settings › Character's Import Character…, Open Example and Open Characters Folder, without any UI (C1).
/// The view shows the open panel and opens files; everything it decides is here, so tests drive it directly.
@MainActor @Observable final class CharacterImportModel {
    /// What Settings says under the buttons after an import.
    enum Notice: Equatable {
        /// "Added Blob.", plus any warnings in plain words.
        case added(String, notes: [String])
        /// The file wasn't added: what's wrong, one sentence per line.
        case failed(file: String, lines: [String])
    }

    private(set) var notice: Notice?
    /// A valid file waiting for "Replace the built-in Zeus?".
    private(set) var pending: CharacterImport.Plan?
    var replacePrompt: String? { pending?.conflict.map(CharacterImport.replacePrompt) }
    @ObservationIgnored let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Validates the file with the real loader. A valid file goes straight in and is selected, unless it would replace
    /// a character: then it waits for `confirmReplace()`. Nothing is copied when it's invalid.
    func importFile(at url: URL) {
        pending = nil
        guard let directory = settings.userCharacterDirectory else { return }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            notice = .failed(file: url.lastPathComponent, lines: ["Zeus couldn't read this file."])
            return
        }
        let builtIn = CharacterLibrary.load(userDirectory: nil).characters
        switch CharacterImport.plan(data: data, source: url.lastPathComponent, userDirectory: directory, builtIn: builtIn) {
        case .failure(let failure):
            notice = .failed(file: url.lastPathComponent, lines: failure.lines)
        case .success(let plan):
            if plan.conflict == nil { install(plan) } else { notice = nil; pending = plan }
        }
    }

    func confirmReplace() {
        guard let plan = pending else { return }
        pending = nil
        install(plan)
    }

    func cancelReplace() { pending = nil }

    /// Writes `Example Character.json` into the Characters folder if it isn't there, and returns it to open.
    func exampleFile() throws -> URL? {
        guard let directory = settings.userCharacterDirectory else { return nil }
        return try CharacterExample.write(into: directory)
    }

    /// The Characters folder, created if needed.
    func charactersFolder() throws -> URL? {
        guard let directory = settings.userCharacterDirectory else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func install(_ plan: CharacterImport.Plan) {
        guard let directory = settings.userCharacterDirectory else { return }
        do {
            try CharacterImport.install(plan, into: directory)
        } catch {
            notice = .failed(file: plan.fileName, lines: ["Zeus couldn't save it in your Characters folder. \(error.localizedDescription)"])
            return
        }
        settings.reloadCharacters()
        settings.currentCharacterID = plan.character.id
        notice = .added(CharacterImport.doneMessage(plan), notes: plan.warnings.map(\.plainMessage))
    }
}

extension AppSettings {
    /// Problems in character files as Settings lists them: one line per file that didn't load, with every reason,
    /// then warnings for files that did. Plain words, never silently skipped.
    var characterProblemLines: [(text: String, isError: Bool)] {
        let errors = Dictionary(grouping: characterProblems.filter { $0.severity == .error }, by: \.source)
        let failed = errors.keys.sorted().map { file in
            (text: "\(file) wasn't loaded. " + (errors[file] ?? []).map(\.plainMessage).joined(separator: " "), isError: true)
        }
        let warnings = characterProblems.filter { $0.severity == .warning && errors[$0.source] == nil }
            .map { (text: "\($0.source): \($0.plainMessage)", isError: false) }
        return failed + warnings
    }
}

/// Watches a folder and the files in it with FSEvents (which also sees editors that save in place) and calls
/// `onChange` once changes settle.
@MainActor final class CharacterFolderWatcher {
    /// Quiet time after the last change before reloading, so a save that touches several files reloads once.
    static let settle: Duration = .milliseconds(300)

    private final class Context: @unchecked Sendable {
        weak var watcher: CharacterFolderWatcher?
    }

    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private let context = Context()
    private let onChange: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private(set) var changeCount = 0

    init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        context.watcher = self
        var info = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(context).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            // The stream delivers on the main queue (below).
            MainActor.assumeIsolated { context.watcher?.changed() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &info, [directory.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func changed() {
        changeCount += 1
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.settle) } catch { return }
            self?.onChange()
        }
    }
}
