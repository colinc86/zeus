import AppKit

extension DocumentViewerModel {
    /// Esc is consumed here while a document is open; only the thread can dismiss the panel.
    @discardableResult func handle(_ command: DocumentKeyboard.Command, conversation: ConversationModel) -> Bool {
        guard isOpen else { return false }
        switch command {
        case .back:
            if findVisible { findVisible = false } else { backRequest += 1 }
        case .open: if let current { openExternally(current) }
        case .reveal: if let current { revealExternally(current) }
        case .expand: expanded.toggle()
        case .find:
            guard supportsFind else { return false }
            findVisible = true; findRequest += 1
        case .previous: _ = step(-1)
        case .next: _ = step(1)
        case .quote: quote(in: conversation); composerRequest += 1
        case .source:
            guard current?.content?.renderer == .markdown else { return false }
            toggleSource()
        case .zoom(let direction):
            guard current?.content?.renderer == .image || current?.content?.renderer == .pdf else { return false }
            zoomDirection = direction; zoomRequest += 1
        }
        return true
    }
    var supportsFind: Bool {
        guard let renderer = current?.content?.renderer else { return false }
        return [.text, .markdown, .pdf].contains(renderer)
    }
}
