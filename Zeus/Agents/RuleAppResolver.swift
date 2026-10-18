import AppKit
import Foundation

/// Resolve display names against permitted observations before consulting installed app metadata.
@MainActor enum RuleAppResolver {
    static func resolve(_ apps: Set<String>, observed: [JournalItem], installed: @MainActor (String) -> Set<String> = installedMatches) throws -> Set<String> {
        guard apps.count <= 100 else { throw ToolArgumentError("trigger.apps must contain at most 100 apps.") }
        return Set(try apps.sorted().map { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if EncryptedJournalStore.isBundleID(name) { return name }
            guard !name.isEmpty, name.count <= 255 else { throw ToolArgumentError("trigger.apps entries must be nonempty app names or bundle IDs, at most 255 characters.") }
            let matches = Set(observed.compactMap { item -> String? in
                guard let id = item.app, EncryptedJournalStore.isBundleID(id) else { return nil }
                let names = [item.payload.value.details["name"], item.payload.value.details["appName"], JournalAppName.displayName(item)]
                return names.compactMap { $0 }.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? id : nil
            })
            let candidates = matches.isEmpty ? installed(name) : matches
            guard candidates.count == 1, let id = candidates.first else {
                if candidates.count > 1 { throw ToolArgumentError("trigger.apps \"\(name)\" matches more than one app; use its bundle ID: " + candidates.sorted().joined(separator: ", ")) }
                throw ToolArgumentError("trigger.apps \"\(name)\" isn't an app Zeus has seen or found installed; use the app's name as shown in the reflection, or its bundle ID.")
            }
            return id
        })
    }

    /// Enumerate application metadata only; never open an app or read its user documents.
    static func installedMatches(_ name: String) -> Set<String> {
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
        var matches = Set<String>()
        for root in roots {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      EncryptedJournalStore.isBundleID(id) else { continue }
                let names = [url.deletingPathExtension().lastPathComponent,
                             bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                             bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
                if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                   NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { matches.insert(id) }
            }
        }
        return matches
    }
}
