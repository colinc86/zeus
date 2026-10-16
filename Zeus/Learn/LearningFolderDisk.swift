import Foundation
import CryptoKit
import Darwin

struct LearningFolderFile: Sendable {
    let path: String
    let data: Data
    let ids: Set<String>
}
enum LearningFolderError: Error { case unsafePath, tooLarge, stale, invalidPicture }

/// A short lock serializes atomic file operations with synchronous erasure. Encoding
/// and ordinary writes run in detached utility work; deletion invalidates that work first.
final class LearningFolderDisk: @unchecked Sendable {
    private struct Entry: Codable { var hash: String; var ids: Set<String> }
    private struct Folder: Codable {
        var files: [String: Entry] = [:]
        var finderDeleted: Set<String> = []
        var erasedHashes: [String: String] = [:]
    }
    private struct State: Codable { var ownFolder: URL?; var folders: [String: Folder] = [:] }
    private let lock = NSLock()
    private let stateURL: URL
    private var state: State
    private var epoch: UInt64 = 0
    init(stateURL: URL) throws {
        self.stateURL = stateURL
        state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) : State()
    }
    var ownFolder: URL? { lock.withLock { state.ownFolder } }
    func setOwnFolder(_ url: URL?) throws { try lock.withLock { state.ownFolder = url; try save() } }
    @discardableResult func invalidate() -> UInt64 { lock.withLock { epoch &+= 1; return epoch } }
    private func key(_ root: URL) -> String { root.standardizedFileURL.path }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func save() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.atomic(JSONEncoder().encode(state), at: stateURL)
    }
    static func atomic(_ data: Data, at target: URL) throws {
        guard data.count <= 16_000_000 else { throw LearningFolderError.tooLarge }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".zeus-write-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temp.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    /// Resolves no links below the selected root. User-selected root links are normalized by the writer.
    private func target(_ root: URL, _ path: String, create: Bool) throws -> URL {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.first == "Zeus", pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw LearningFolderError.unsafePath }
        var current = root
        for (i, part) in pieces.enumerated() {
            current.appendPathComponent(part)
            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true else { throw LearningFolderError.unsafePath }
            if i < pieces.count - 1 {
                if create { try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                if FileManager.default.fileExists(atPath: current.path) {
                    guard (try current.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw LearningFolderError.unsafePath }
                    if create { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path) }
                }
            }
        }
        return current
    }
    func existing(_ root: URL, path: String) -> URL? {
        lock.withLock {
            guard let url = try? target(root, path, create: false), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }
    func apply(_ files: [LearningFolderFile], root: URL, token: UInt64) throws {
        try lock.withLock {
            guard epoch == token else { throw LearningFolderError.stale }
            let k = key(root); var folder = state.folders[k] ?? Folder()
            for file in files {
                let url = try target(root, file.path, create: false), hash = Self.hash(file.data)
                if folder.files[file.path] != nil && !FileManager.default.fileExists(atPath: url.path) {
                    folder.finderDeleted.insert(file.path); folder.files.removeValue(forKey: file.path)
                }
                if folder.finderDeleted.contains(file.path) || folder.erasedHashes[file.path] == hash { continue }
                if folder.files[file.path]?.hash != hash {
                    _ = try target(root, file.path, create: true)
                    try Self.atomic(file.data, at: url)
                }
                folder.erasedHashes.removeValue(forKey: file.path)
                folder.files[file.path] = Entry(hash: hash, ids: file.ids)
                state.folders[k] = folder
            }
            state.folders[k] = folder; try save()
        }
    }
    func prune(root: URL, keeping: Set<String>, token: UInt64) throws {
        try lock.withLock {
            guard epoch == token else { throw LearningFolderError.stale }
            let k = key(root); var folder = state.folders[k] ?? Folder()
            for path in folder.files.keys where !keeping.contains(path) {
                let url = try target(root, path, create: false)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                folder.files.removeValue(forKey: path)
            }
            state.folders[k] = folder; try save()
        }
    }
    func erase(root: URL, ids: Set<String>?, includeNotes: Bool = false) throws {
        try lock.withLock {
            epoch &+= 1
            let k = key(root); var folder = state.folders[k] ?? Folder()
            if let ids {
                for (path, entry) in folder.files where !entry.ids.isDisjoint(with: ids) {
                    let url = try target(root, path, create: false)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    folder.files.removeValue(forKey: path)
                }
            } else {
                folder.erasedHashes.merge(folder.files.mapValues(\.hash)) { _, new in new }
                let zone = try target(root, "Zeus", create: false)
                if FileManager.default.fileExists(atPath: zone.path) {
                    for url in try FileManager.default.contentsOfDirectory(at: zone, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
                }
                folder.files.removeAll()
                if includeNotes {
                    let notes = root.appendingPathComponent("Notes")
                    guard (try? notes.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw LearningFolderError.unsafePath }
                    if FileManager.default.fileExists(atPath: notes.path) {
                        for url in try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
                    }
                }
            }
            state.folders[k] = folder; try save()
        }
    }
}
