import Foundation
import UniformTypeIdentifiers
import ZeusProtocol

/// Only text is read into memory here. Native previewers receive a revalidated local URL.
enum DocumentRenderer: String, Sendable { case markdown, text, image, pdf, quickLook, folder, missing, unsupported, revealOnly }
struct DocumentFolderItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isFolder: Bool
    let kind: String
    let modified: Date?
}
struct DocumentContent: Sendable {
    var renderer: DocumentRenderer
    var text: String?
    var truncated = false
    var items: [DocumentFolderItem] = []
    var size: Int64 = 0
    var modified: Date?
    var error: String?
}

enum DocumentLoader {
    static let textLimit = 5_000_000
    static func renderer(for url: URL) -> DocumentRenderer {
        guard url.isFileURL else { return .unsupported }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard !AttachmentTarget.requiresReveal(url.resolvingSymlinksInPath()) else { return .revealOnly }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return .folder }
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        if ext == "pdf" { return .pdf }
        let type = values?.contentType ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return .image }
        // CSV and HTML deliberately use Quick Look rather than the plain-text renderer.
        if ["csv", "html", "htm", "svg"].contains(ext) { return .quickLook }
        if ["txt", "log", "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "xml", "css", "c", "h", "cpp", "rs", "go", "sql", "rb", "java", "kt", "ini", "diff"].contains(ext) || type?.conforms(to: .plainText) == true { return .text }
        if type == nil || type == .data || type?.isDynamic == true { return .unsupported }
        return .quickLook
    }
    static func load(_ original: URL, limit: Int = textLimit) -> DocumentContent {
        let url = original.resolvingSymlinksInPath()
        let renderer = renderer(for: url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var result = DocumentContent(renderer: renderer, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        do {
            switch renderer {
            case .markdown, .text:
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: max(0, limit) + 1) ?? Data()
                result.truncated = data.count > limit
                let prefix = Data(data.prefix(max(0, limit)))
                result.text = String(data: prefix, encoding: .utf8) ?? String(data: prefix, encoding: .utf16) ?? String(decoding: prefix, as: UTF8.self)
                if result.truncated, let text = result.text, let end = text.lastIndex(of: "\n"), end > text.startIndex { result.text = String(text[..<end]) }
            case .folder:
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey, .contentModificationDateKey]
                result.items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]).map { child in
                    let v = try? child.resourceValues(forKeys: keys)
                    return .init(url: child, name: child.lastPathComponent, isFolder: v?.isDirectory == true && v?.isPackage != true,
                                 kind: folderKind(isFolder: v?.isDirectory == true && v?.isPackage != true, description: v?.localizedTypeDescription, extension: child.pathExtension), modified: v?.contentModificationDate)
                }.sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            default: break
            }
        } catch { result.renderer = .unsupported; result.error = error.localizedDescription }
        return result
    }

    static func folderKind(isFolder: Bool, description: String?, extension ext: String) -> String {
        if isFolder { return "Folder" }
        if let description, !description.isEmpty { return description.prefix(1).uppercased() + description.dropFirst() }
        return ext.isEmpty ? "Document" : ext.uppercased()
    }
    static func modifiedLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "H:mm"; return "Today " + formatter.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Markdown images never leave the document's own directory, including through a symlink.
    static func localImage(_ reference: String, document: URL) -> URL? {
        guard let url = localLink(reference, document: document) else { return nil }
        let folder = document.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(folder), renderer(for: url) == .image else { return nil }
        return url
    }
    static func localLink(_ reference: String, document: URL) -> URL? {
        guard !reference.hasPrefix("//"), let value = URL(string: reference, relativeTo: document), value.isFileURL else { return nil }
        let resolved = value.standardizedFileURL.resolvingSymlinksInPath()
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
        components?.fragment = value.fragment?.removingPercentEncoding ?? value.fragment
        return components?.url
    }
}
