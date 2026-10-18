import AppKit
import SwiftUI
import ZeusProtocol

/// The ordinary chip keeps its browser/reveal behavior when no document host is installed.
struct DocumentOpeningKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Attachment, String?) -> Bool)? = nil
}
struct LearningDocumentOpeningKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ThreadNotice) -> Void)? = nil
}
extension EnvironmentValues {
    var openLearningDocument: (@MainActor (ThreadNotice) -> Void)? {
        get { self[LearningDocumentOpeningKey.self] }
        set { self[LearningDocumentOpeningKey.self] = newValue }
    }
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
        guard !page.isSnapshot, let action = AttachmentTarget.action(for: page.attachment) else { return }
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
        guard !page.isSnapshot else { return }
        _ = AttachmentChip.perform(page.attachment, .reveal)
    }
    static func copy(_ page: DocumentViewerModel.Page) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(page.isSnapshot ? page.content?.text ?? "" : page.url.path, forType: .string)
    }
}
