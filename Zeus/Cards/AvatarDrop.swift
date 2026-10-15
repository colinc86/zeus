import AppKit
import UniformTypeIdentifiers
import ZeusProtocol

/// Explicit user drops are draft attachments, never observations. No remote URL is fetched or file opened.
@MainActor
enum AvatarDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]
    static let maximumItems = 32
    static let maximumBytes = 32 * 1_024 * 1_024

    struct Result {
        var attachments: [Attachment] = []
        var error: String?
    }

    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }

    static func read(_ pasteboard: NSPasteboard, directory: URL) -> Result {
        var result = Result()
        for item in (pasteboard.pasteboardItems ?? []).prefix(maximumItems) {
            do {
                if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
                    guard values.isReadable == true else { throw DropError.unreadable }
                    result.attachments.append(Attachment(kind: values.isDirectory == true ? .folder : .file,
                                                         label: url.lastPathComponent, target: url.path))
                } else if let value = item.string(forType: .URL), let url = URL(string: value),
                          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                          url.user == nil, url.password == nil {
                    result.attachments.append(Attachment(kind: .url, label: url.host ?? "Link", target: url.absoluteString))
                } else if let data = item.data(forType: .png) ?? item.data(forType: .tiff) {
                    let ext = item.availableType(from: [.png]) != nil ? "png" : "tiff"
                    let url = try save(data, extension: ext, directory: directory)
                    result.attachments.append(Attachment(kind: .file, label: "Dropped image.\(ext)", target: url.path))
                } else if let text = item.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Text is kept as an explicit file attachment, so removing its chip removes it from the send too.
                    let url = try save(Data(text.utf8), extension: "txt", directory: directory)
                    result.attachments.append(Attachment(kind: .file, label: "Dropped text.txt", target: url.path))
                }
            } catch { result.error = "Couldn't attach an item. \(error.localizedDescription)" }
        }
        if (pasteboard.pasteboardItems?.count ?? 0) > maximumItems { result.error = "Attach up to \(maximumItems) items at a time." }
        return result
    }

    private static func save(_ data: Data, extension ext: String, directory: URL) throws -> URL {
        guard data.count <= maximumBytes else { throw DropError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private enum DropError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self { case .unreadable: "This file isn't readable."; case .tooLarge: "Dropped text and images must be under 32 MB." }
        }
    }
}

extension ConversationModel {
    /// References travel through the existing durable message path; images are files, never inline base64.
    static func message(_ draft: String, attaching items: [Attachment]) -> String {
        guard !items.isEmpty else { return MessageText.submitted(draft) }
        let text = MessageText.submitted(draft)
        let references = items.map { item in
            let target = item.kind == .url ? item.target : URL(fileURLWithPath: item.target).absoluteString
            return "- \(item.kind.rawValue): \(target)"
        }.joined(separator: "\n")
        return (text.isEmpty ? "Please look at the attached items." : text) + "\n\nAttachments:\n" + references
    }
}
