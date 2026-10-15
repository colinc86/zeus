import Foundation
import CryptoKit
import ZeusProtocol

/// Template synchronization only touches exact known files. Unknown and symlink
/// content is never silently overwritten, including a missing file in a user folder.
enum ManagedTemplateSetup {
    static let names = ["AGENTS.md", "CLAUDE.md"]
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static let toolsHash: String = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash((try? encoder.encode(ZeusMCP.tools)) ?? Data())
    }()
    static func snapshot(folder: String) -> ManagedTemplateReplacement {
        var hashes: [String: String] = [:]
        for name in names {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { hashes[name] = "symlink" }
            else if values?.isRegularFile == true, let bytes = try? Data(contentsOf: url) { hashes[name] = hash(bytes) }
            else { hashes[name] = "missing-or-unreadable" }
        }
        return .init(folder: folder, hashes: hashes)
    }
    static func isShipped(_ hash: String, name: String) -> Bool {
        ManagedTemplateHistory.legacyHashes[name]?.contains(hash) == true
            || ManagedTemplateHistory.versions.values.contains { $0[name] == hash }
    }
    static func edited(_ snapshot: ManagedTemplateReplacement) -> Bool {
        names.contains { !isShipped(snapshot.hashes[$0] ?? "", name: $0) }
    }
    static func refresh(folder: String, resources: URL?, confirmed: ManagedTemplateReplacement? = nil) throws {
        guard let resources else { return }
        let before = snapshot(folder: folder)
        if confirmed != nil, before.hashes.values.contains("symlink") { throw ManagedSessionError.command("Linked assistant instructions must be edited in Terminal.") }
        if let confirmed, confirmed != before { throw ManagedSessionError.command("The assistant folder changed. Review it before replacing its instructions.") }
        for name in names {
            guard let old = before.hashes[name], old != "symlink",
                  confirmed != nil || isShipped(old, name: name) else { continue }
            let current = try Data(contentsOf: resources.appendingPathComponent(name))
            guard hash(current) == ManagedTemplateHistory.versions[ManagedTemplateHistory.version]?[name] else {
                throw ManagedSessionError.command("Zeus's bundled assistant template is not the expected version.")
            }
            if old != hash(current) {
                guard snapshot(folder: folder).hashes[name] == old else { throw ManagedSessionError.command("The assistant instructions changed. Review them again.") }
                try current.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name), options: .atomic)
            }
        }
    }
}
