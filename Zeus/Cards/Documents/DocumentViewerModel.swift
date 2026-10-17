import Foundation
import Observation
import ZeusProtocol

@MainActor @Observable
final class DocumentViewerModel {
    struct Page: Identifiable, Sendable {
        let id = UUID()
        let attachment: Attachment
        let sourceCardID: String?
        let context: String?
        var url: URL { URL(fileURLWithPath: attachment.target) }
        var content: DocumentContent?
        var source = false
    }
    private(set) var pages: [Page] = []
    private(set) var loading = false
    private(set) var revision = 0
    private(set) var updatedAt: Date?
    var expanded = false
    private(set) var navigationDirection = 1
    var selectedText = ""
    var findRequest = 0
    var findVisible = false
    var findText = ""
    var findIndex = 0
    var findCount = 0
    var zoomRequest = 0
    var zoomDirection = 0
    var pdfPage: String?
    var backRequest = 0
    var composerRequest = 0
    var quoteRequest = 0
    var autoAttachedPage: UUID?
    var threadOffset: CGFloat?
    var threadPageCount = ConversationLayout.pageSize
    var fromPeek = false
    var attachmentPosition: String? { attachments.count > 1 ? "\(attachmentIndex + 1)/\(attachments.count)" : nil }
    var returnTarget: ConversationControlTarget?
    @ObservationIgnored var openExternally: (Page) -> Void = { DocumentActions.open($0) }
    @ObservationIgnored var revealExternally: (Page) -> Void = { DocumentActions.reveal($0) }
    @ObservationIgnored var offsets: [UUID: CGPoint] = [:]
    @ObservationIgnored private var attachments: [Attachment] = []
    @ObservationIgnored private var attachmentIndex = 0
    @ObservationIgnored private var watcher: DocumentFileWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var fingerprint: String?
    var current: Page? { pages.last }
    var isOpen: Bool { !pages.isEmpty }
    var canPrevious: Bool { attachmentIndex > 0 }
    var canNext: Bool { attachmentIndex + 1 < attachments.count }

    /// False leaves web links and reveal-only attachments on their existing workspace path.
    @discardableResult func open(_ attachment: Attachment, siblings: [Attachment] = [], sourceCardID: String? = nil, context: String? = nil) -> Bool {
        guard case .open(let url)? = AttachmentTarget.action(for: attachment), url.isFileURL else { return false }
        var value = attachment; value.target = url.path
        attachments = siblings.filter { $0.kind != .url }
        if let index = attachments.firstIndex(where: { $0.id == attachment.id }) { attachmentIndex = index }
        else { attachments = [value]; attachmentIndex = 0 }
        returnTarget = sourceCardID.map { .init(entryID: "card:\($0)", controlID: "open:\(attachment.id)") }
        offsets.removeAll()
        pages = [.init(attachment: value, sourceCardID: sourceCardID, context: context)]
        activate()
        return true
    }
    @discardableResult func navigate(_ url: URL) -> Bool {
        let kind: Attachment.Kind = DocumentLoader.renderer(for: url) == .folder ? .folder : .file
        let value = Attachment(kind: kind, label: url.lastPathComponent, target: url.path)
        guard url.isFileURL, case .open(let safe)? = AttachmentTarget.action(for: value), safe.isFileURL else { return false }
        let parent = current
        navigationDirection = 1
        pages.append(.init(attachment: .init(kind: kind, label: safe.lastPathComponent, target: safe.path), sourceCardID: parent?.sourceCardID, context: parent?.context))
        activate(); return true
    }
    /// Returns true when Back reaches the conversation rather than another document.
    @discardableResult func back() -> Bool {
        guard !pages.isEmpty else { return true }
        navigationDirection = -1
        pages.removeLast()
        if pages.isEmpty { stop() } else { activate() }
        return pages.isEmpty
    }
    func close() { pages.removeAll(); offsets.removeAll(); stop() }
    @discardableResult func step(_ direction: Int) -> Bool {
        let next = attachmentIndex + direction
        guard attachments.indices.contains(next), let root = pages.first else { return false }
        let item = attachments[next]
        guard case .open(let url)? = AttachmentTarget.action(for: item), url.isFileURL else { return false }
        navigationDirection = direction < 0 ? -1 : 1
        attachmentIndex = next
        var value = item; value.target = url.path
        pages = [.init(attachment: value, sourceCardID: root.sourceCardID, context: root.context)]
        activate(); return true
    }
    func toggleSource() { guard !pages.isEmpty else { return }; pages[pages.count - 1].source.toggle() }
    func ask(in conversation: ConversationModel) {
        guard let page = current else { return }
        autoAttachedPage = page.id
        if !conversation.draftAttachments.contains(where: { $0.target == page.attachment.target }) {
            conversation.draftAttachments.append(page.attachment)
        }
    }
    func quote(in conversation: ConversationModel) {
        guard current != nil, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ask(in: conversation)
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let passage = String(trimmed.prefix(2_000)) + (trimmed.count > 2_000 ? "…" : "")
        let quote = passage.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        if !conversation.draft.isEmpty { conversation.draft += "\n\n" }
        conversation.draft += "\(quote)\n\n"
    }
    func typed(in conversation: ConversationModel) {
        guard let page = current, autoAttachedPage != page.id, !conversation.draft.isEmpty else { return }
        autoAttachedPage = page.id; ask(in: conversation)
    }
    func refresh() { load(updated: true) }
    private func activate() {
        stop(); selectedText = ""; updatedAt = nil; findVisible = false; findText = ""; findCount = 0; pdfPage = nil; autoAttachedPage = nil
        guard let url = current?.url else { return }
        fingerprint = Self.fingerprint(url)
        installWatch(url)
        load(updated: false)
    }
    private func installWatch(_ url: URL) {
        watcher = DocumentFileWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }
    private func stop() {
        generation = UUID(); watcher = nil; loadTask?.cancel(); refreshTask?.cancel()
        loadTask = nil; refreshTask = nil; loading = false
    }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let url = self.current?.url else { return }
            let value = Self.fingerprint(url)
            guard self.fingerprint != value else { return }
            self.fingerprint = value; self.installWatch(url); self.load(updated: true)
        }
    }
    private func load(updated: Bool) {
        guard let page = current else { return }
        loadTask?.cancel(); generation = UUID(); let token = generation
        loading = page.content == nil
        loadTask = Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) { DocumentLoader.load(page.url) }.value
            guard !Task.isCancelled, let self, self.generation == token, self.current?.id == page.id else { return }
            self.pages[self.pages.count - 1].content = content
            self.loading = false; self.revision += 1
            if updated { self.updatedAt = Date() }
        }
    }
    private static func fingerprint(_ url: URL) -> String {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\((values?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0):\(String(describing: values?[.size])):\(String(describing: values?[.systemFileNumber]))"
    }
}
