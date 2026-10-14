import AppKit
import CoreServices
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign

/// Import…, Open Example and Open … Folder for a folder of user JSON files: characters (C1) and themes (T1).
/// Everything it decides is here, without UI, so tests drive it directly; `LibraryFileActions` is the view.
@MainActor @Observable final class LibraryImportModel {
    /// What Settings says under the buttons after an import.
    enum Notice: Equatable {
        /// "Added Blob.", plus any notes (warnings, low contrast) in plain words.
        case added(String, notes: [String])
        /// The file wasn't added: what's wrong, one sentence per line.
        case failed(file: String, lines: [String])
    }

    /// A valid file, ready to install.
    struct Plan {
        /// "Replace the built-in Zeus?" when it replaces something; nil installs straight away.
        let prompt: String?
        let done: String
        let notes: [String]
        let install: (URL) throws -> Void
        /// Select it after installing.
        let select: @MainActor () -> Void
    }

    /// What differs between characters and themes.
    struct Kind {
        let importTitle: String
        let exampleTitle = "Open Example"
        let folderTitle: String
        let panelMessage: String
        let directory: @MainActor () -> URL?
        /// Validates a file's bytes against the folder: a plan, or what's wrong.
        let plan: @MainActor (_ data: Data, _ source: String, _ directory: URL) -> Result<Plan, LineFailure>
        let writeExample: (URL) throws -> URL
        let reload: @MainActor () -> Void
    }

    struct LineFailure: Error { let lines: [String] }

    let kind: Kind
    private(set) var notice: Notice?
    /// A valid file waiting for its replace prompt to be answered.
    private(set) var pending: Plan?
    var replacePrompt: String? { pending?.prompt }

    init(kind: Kind) {
        self.kind = kind
    }

    /// Validates the file with the real loader. A valid file goes straight in and is selected, unless it would replace
    /// something: then it waits for `confirmReplace()`. Nothing is copied when it's invalid.
    func importFile(at url: URL) {
        pending = nil
        guard let directory = kind.directory() else { return }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            notice = .failed(file: url.lastPathComponent, lines: ["Zeus couldn't read this file."])
            return
        }
        switch kind.plan(data, url.lastPathComponent, directory) {
        case .failure(let failure): notice = .failed(file: url.lastPathComponent, lines: failure.lines)
        case .success(let plan):
            if plan.prompt == nil { install(plan, into: directory) } else { notice = nil; pending = plan }
        }
    }

    func confirmReplace() {
        guard let plan = pending, let directory = kind.directory() else { return }
        pending = nil
        install(plan, into: directory)
    }

    func cancelReplace() { pending = nil }

    /// Writes the example into the folder if it isn't there, and returns it to open.
    func exampleFile() throws -> URL? {
        guard let directory = kind.directory() else { return nil }
        return try kind.writeExample(directory)
    }

    /// The folder, created if needed.
    func folder() throws -> URL? {
        guard let directory = kind.directory() else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func install(_ plan: Plan, into directory: URL) {
        do { try plan.install(directory) } catch {
            notice = .failed(file: directory.lastPathComponent, lines: ["Zeus couldn't save it in your \(directory.lastPathComponent) folder. \(error.localizedDescription)"])
            return
        }
        kind.reload()
        plan.select()
        notice = .added(plan.done, notes: plan.notes)
    }
}

/// The three buttons, the replace confirmation and the result notice, shared by Settings › Character and › Appearance.
struct LibraryFileActions: View {
    @Bindable var model: LibraryImportModel
    @State private var choosingFile = false
    @FocusState private var cancelFocused: Bool
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(model.kind.importTitle) { chooseFile() }.accessibilityLabel(model.kind.importTitle).disabled(choosingFile)
                Button(model.kind.exampleTitle) { open(try? model.exampleFile()) }.accessibilityLabel(model.kind.exampleTitle)
                Button(model.kind.folderTitle) { open(try? model.folder()) }.accessibilityLabel(model.kind.folderTitle)
            }
            if let prompt = model.replacePrompt { replaceConfirmation(prompt) }
            notice
        }
    }

    @ViewBuilder private var notice: some View {
        switch model.notice {
        case .added(let message, let notes)?:
            Text(message).settingsBody()
            ForEach(notes, id: \.self) { Text($0).settingsCaption() }
        case .failed(let file, let lines)?:
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't add \(file).").settingsError()
                ForEach(lines, id: \.self) { Text($0).settingsError() }
            }
        case nil:
            EmptyView()
        }
    }

    /// Replacing is the risky choice, so Cancel has focus and Esc (as in Settings › Assistant's confirmations).
    private func replaceConfirmation(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text(prompt).zeusFont(.caption).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZeusTheme.Spacing.s) {
                Button("Replace") { model.confirmReplace() }.accessibilityLabel("Replace")
                    .buttonStyle(ZeusButtonStyle(.destructive, size: .small)).focusable()
                Button("Cancel") { model.cancelReplace() }.accessibilityLabel("Cancel")
                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    .focusable().focused($cancelFocused).keyboardShortcut(.cancelAction)
            }
        }
        .padding(ZeusTheme.Spacing.s).background(palette.field)
        .onAppear { cancelFocused = true }
    }

    private func chooseFile() {
        guard !choosingFile else { return }
        choosingFile = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"; panel.message = model.kind.panelMessage
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            choosingFile = false
            if response == .OK, let url = panel.url { model.importFile(at: url) }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    /// Opens a file in its default app (or a folder in Finder); shows it in Finder when nothing can open it.
    private func open(_ url: URL?) {
        guard let url else { return }
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

/// Watches a folder and the files in it with FSEvents (which also sees editors that save in place) and calls
/// `onChange` once changes settle.
@MainActor final class FolderWatcher {
    /// Quiet time after the last change before reloading, so a save that touches several files reloads once.
    static let settle: Duration = .milliseconds(300)

    private final class Context: @unchecked Sendable {
        weak var watcher: FolderWatcher?
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
