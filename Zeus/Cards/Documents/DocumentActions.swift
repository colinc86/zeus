import AppKit
import SwiftUI
import ZeusProtocol

/// The ordinary chip keeps its browser/reveal behavior when no document host is installed.
struct DocumentOpeningKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Attachment, String?) -> Bool)? = nil
}
extension EnvironmentValues {
    var openDocument: (@MainActor (Attachment, String?) -> Bool)? {
        get { self[DocumentOpeningKey.self] }
        set { self[DocumentOpeningKey.self] = newValue }
    }
}

@MainActor enum DocumentActions {
    static func application(for url: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: url) }
    static func applicationName(for url: URL) -> String? {
        application(for: url).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }
    static func open(_ page: DocumentViewerModel.Page, application: URL? = nil) {
        guard let action = AttachmentTarget.action(for: page.attachment) else { return }
        switch action {
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .open(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { reveal(page); return }
            if let application {
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        }
    }
    static func reveal(_ page: DocumentViewerModel.Page) {
        _ = AttachmentChip.perform(page.attachment, .reveal)
    }
    static func copy(_ page: DocumentViewerModel.Page) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(page.url.path, forType: .string)
    }
}
