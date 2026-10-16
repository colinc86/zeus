import AppKit
import Observation

/// Presents the effective destination; the writer owns persistence and managed-folder precedence.
@MainActor @Observable final class LearningFolderModel {
    var provider: (any LearningFolderProviding)?
    @ObservationIgnored var pickFolder: () -> URL? = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
    @ObservationIgnored var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    init(provider: (any LearningFolderProviding)? = nil) { self.provider = provider }
    var folderURL: URL? { provider?.folderURL }
    var recordURL: URL? { folderURL?.appendingPathComponent("Zeus", isDirectory: true) }
    var path: String? { recordURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } }
    var writeFailed: Bool { provider?.lastWriteError != nil }
    func choose() { if let folder = pickFolder() { provider?.setFolder(folder) } }
    func stopKeepingFolder() { provider?.setFolder(nil) }
    func showFolder() { if let recordURL { reveal(recordURL) } }
    func show(_ item: JournalItem) { if let url = provider?.fileURL(forJournalItem: item) { reveal(url) } }
}
