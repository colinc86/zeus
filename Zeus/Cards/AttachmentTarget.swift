import Foundation
import UniformTypeIdentifiers
import ZeusProtocol

/// Converts attachment data to a workspace target; remote links are limited to web URLs.
enum AttachmentTarget {
    enum Action: Equatable {
        case open(URL)
        case reveal(URL)
    }
    static let safetyCaption = "Zeus shows apps and scripts in Finder instead of opening them."

    /// Resolve the final target before deciding whether Launch Services may open it.
    static func action(for attachment: Attachment, reveal: Bool = false) -> Action? {
        guard let original = url(for: attachment) else { return nil }
        guard original.isFileURL else { return .open(original) }
        let target = original.resolvingSymlinksInPath()
        if reveal || requiresReveal(target) { return .reveal(target) }
        return .open(target)
    }

    static func requiresReveal(_ target: URL) -> Bool {
        let values = try? target.resourceValues(forKeys: [.contentTypeKey, .isPackageKey, .isDirectoryKey, .isAliasFileKey])
        if values?.isPackage == true || values?.isAliasFile == true { return true }
        // These Launch Services types include documents whose handler executes their content.
        let executableExtensions: Set<String> = ["app", "command", "terminal", "workflow", "pkg", "mpkg", "scpt", "scptd", "sh", "bash", "zsh", "fish", "bundle", "framework", "plugin", "kext", "appex", "xpc"]
        if executableExtensions.contains(target.pathExtension.lowercased()) { return true }
        let declaredType = UTType(filenameExtension: target.pathExtension)
        let type = values?.contentType ?? declaredType
        let types = [values?.contentType, declaredType].compactMap { $0 }
        let executableTypes: [UTType] = [.application, .executable, .script, .shellScript, .unixExecutable, .bundle]
        if types.contains(where: { type in executableTypes.contains { type.conforms(to: $0) } }) { return true }
        if let installer = UTType("com.apple.installer-package-archive"), types.contains(where: { $0.conforms(to: installer) }) { return true }
        if values?.isDirectory == true { return false } // Ordinary folders open in Finder.
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        if attributes?[.type] as? FileAttributeType == .typeRegular, hasExecutableHeader(target) { return true }
        if let kind = attributes?[.type] as? FileAttributeType, kind != .typeRegular { return true }
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let document = type?.conforms(to: .content) == true && type?.conforms(to: .executable) != true
        return mode & 0o111 != 0 && !document
    }

    private static func hasExecutableHeader(_ target: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: target) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4) else { return false }
        let bytes = Array(data)
        if bytes.starts(with: [0x23, 0x21]) { return true } // A script can have a document extension.
        let signatures: [[UInt8]] = [[0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
                [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF],
                [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
                [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA],
                [0x7F, 0x45, 0x4C, 0x46]]
        return signatures.contains(bytes)
    }

    static func locationCaption(for attachment: Attachment) -> String {
        guard attachment.kind != .url, let url = url(for: attachment) else { return attachment.target }
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }

    static func url(for attachment: Attachment) -> URL? {
        switch attachment.kind {
        case .file, .folder:
            let path = (attachment.target as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: attachment.kind == .folder)
        case .url:
            guard let url = URL(string: attachment.target),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else { return nil }
            return url
        }
    }
}
