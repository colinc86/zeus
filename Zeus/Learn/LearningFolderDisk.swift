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
        var directories: Set<String>?
        var temporaryFiles: Set<String>?
    }
    private struct State: Codable { var ownFolder: URL?; var folders: [String: Folder] = [:] }
    private let lock = NSLock()
    private let stateURL: URL
    private var state: State
    private var epoch: UInt64 = 0
    private var collisions: Set<String> = []
    init(stateURL: URL) throws {
        self.stateURL = stateURL
        state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) : State()
    }
    var ownFolder: URL? { lock.withLock { state.ownFolder } }
    func setOwnFolder(_ url: URL?) throws { try lock.withLock { state.ownFolder = url; try save() } }
    @discardableResult func invalidate() -> UInt64 { lock.withLock { epoch &+= 1; collisions.removeAll(); return epoch } }
    var collisionPaths: [String] { lock.withLock { collisions.sorted() } }
    private func key(_ root: URL) -> String { root.standardizedFileURL.path }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func save() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.atomic(JSONEncoder().encode(state), at: stateURL)
    }
    static func atomic(_ data: Data, at target: URL, temporaryURL: URL? = nil, replacing: Bool = true) throws {
        guard data.count <= 16_000_000 else { throw LearningFolderError.tooLarge }
        let temp = temporaryURL ?? target.deletingLastPathComponent().appendingPathComponent(".zeus-write-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data); try handle.synchronize()
        let result = replacing ? rename(temp.path, target.path) : renamex_np(temp.path, target.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
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
                if create && !FileManager.default.fileExists(atPath: current.path) { try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                if FileManager.default.fileExists(atPath: current.path) {
                    guard (try current.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw LearningFolderError.unsafePath }
                }
            }
        }
        return current
    }
    func existing(_ root: URL, path: String) -> URL? {
        lock.withLock {
            guard state.folders[key(root)]?.files[path] != nil,
                  let url = try? target(root, path, create: false), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }
    func existingDirectory(_ root: URL, path: String) -> URL? {
        lock.withLock {
            guard state.folders[key(root)]?.files.keys.contains(where: { $0.hasPrefix(path + "/") }) == true,
                  let url = try? target(root, path, create: false),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return url
        }
    }
    /// Journal frame IDs are immutable (replacement under an existing ID is rejected).
    /// Avoid decrypting/re-encoding every retained image on each activity append.
    func reuseFrame(root: URL, path: String, id: String, token: UInt64) throws -> Bool {
        try lock.withLock {
            guard epoch == token else { throw LearningFolderError.stale }
            let k = key(root); var folder = state.folders[k] ?? Folder()
            if folder.finderDeleted.contains(path) { return true }
            guard folder.files[path]?.ids == Set([id]) else { return false }
            let url = try target(root, path, create: false)
            if FileManager.default.fileExists(atPath: url.path) { return true }
            folder.finderDeleted.insert(path); folder.files.removeValue(forKey: path)
            state.folders[k] = folder; try save()
            return true
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
                let exists = FileManager.default.fileExists(atPath: url.path)
                if exists, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
                    collisions.insert(file.path); continue
                }
                if exists && folder.files[file.path] == nil {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.fileSize == file.data.count,
                          Self.hash(try Data(contentsOf: url)) == hash else {
                        collisions.insert(file.path); continue
                    }
                } else if folder.files[file.path]?.hash != hash {
                    try prepareDirectories(root: root, path: file.path, folder: &folder)
                    let tempPath = (file.path as NSString).deletingLastPathComponent + "/.zeus-write-" + UUID().uuidString
                    folder.temporaryFiles = (folder.temporaryFiles ?? []).union([tempPath])
                    state.folders[k] = folder; try save()
                    do {
                        try Self.atomic(file.data, at: url, temporaryURL: target(root, tempPath, create: false), replacing: folder.files[file.path] != nil)
                    } catch let error as POSIXError where error.code == .EEXIST {
                        collisions.insert(file.path); folder.temporaryFiles?.remove(tempPath)
                        continue
                    }
                    folder.temporaryFiles?.remove(tempPath)
                }
                collisions.remove(file.path)
                folder.erasedHashes.removeValue(forKey: file.path)
                folder.files[file.path] = Entry(hash: hash, ids: file.ids)
                state.folders[k] = folder
            }
            state.folders[k] = folder; try save()
        }
    }
    private func prepareDirectories(root: URL, path: String, folder: inout Folder) throws {
        let parts = path.split(separator: "/").dropLast()
        for count in 1...parts.count {
            let relative = parts.prefix(count).joined(separator: "/")
            let url = try target(root, relative, create: false)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                folder.directories = (folder.directories ?? []).union([relative])
            }
        }
    }
    /// unlink cannot recursively remove a directory substituted at a previously owned file path.
    private func removeFile(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    private func removeEmptyDirectories(root: URL, folder: inout Folder) throws {
        for path in (folder.directories ?? []).sorted(by: { $0.count > $1.count }) {
            let url = try target(root, path, create: false)
            if rmdir(url.path) == 0 || errno == ENOENT { folder.directories?.remove(path) }
            else if errno != ENOTEMPTY && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }
    func prune(root: URL, keeping: Set<String>, token: UInt64) throws {
        try lock.withLock {
            guard epoch == token else { throw LearningFolderError.stale }
            let k = key(root); var folder = state.folders[k] ?? Folder()
            for path in folder.files.keys where !keeping.contains(path) {
                let url = try target(root, path, create: false)
                if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
                else { folder.finderDeleted.insert(path) }
                folder.files.removeValue(forKey: path)
            }
            try removeEmptyDirectories(root: root, folder: &folder)
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
                    if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
                    folder.files.removeValue(forKey: path)
                }
            } else {
                folder.erasedHashes.merge(folder.files.mapValues(\.hash)) { _, new in new }
                for path in folder.files.keys {
                    try removeFile(target(root, path, create: false))
                }
                for path in folder.temporaryFiles ?? [] {
                    try removeFile(target(root, path, create: false))
                }
                folder.temporaryFiles = []
                folder.files.removeAll()
                if includeNotes {
                    let notes = root.appendingPathComponent("Notes")
                    guard (try? notes.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw LearningFolderError.unsafePath }
                    if FileManager.default.fileExists(atPath: notes.path) {
                        for url in try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
                    }
                }
            }
            try removeEmptyDirectories(root: root, folder: &folder)
            state.folders[k] = folder; try save()
        }
    }
}
