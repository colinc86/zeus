import AppKit
import Foundation

/// Resolve display names against permitted observations before consulting installed app metadata.
@MainActor enum RuleAppResolver {
    static func resolve(_ apps: Set<String>, observed: [JournalItem], installed: @MainActor (String) -> Set<String> = installedMatches) throws -> Set<String> {
        guard apps.count <= 100 else { throw ToolArgumentError("trigger.apps must contain at most 100 apps.") }
        return Set(try apps.sorted().map { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if JournalAppName.isBundleID(name) { return name }
            guard !name.isEmpty, name.count <= 255 else { throw ToolArgumentError("trigger.apps entries must be nonempty app names or bundle IDs, at most 255 characters.") }
            let matches = Set(observed.compactMap { item -> String? in
                guard let id = item.app, JournalAppName.isBundleID(id) else { return nil }
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
                      JournalAppName.isBundleID(id) else { continue }
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

@MainActor enum RuleProposalValidation {
    static func validate(_ proposal: RuleProposal) throws {
        guard proposal.trigger.kind == nil || proposal.trigger.kind == "spend" else { throw ToolArgumentError("trigger.kind must be spend or omitted.") }
        let text = proposal.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { throw ToolArgumentError("sentence must contain 1–500 characters.") }
        guard proposal.confidence.isFinite, (0...1).contains(proposal.confidence) else { throw ToolArgumentError("confidence must be a finite number between 0 and 1.") }
        guard proposal.evidence.count <= 100, proposal.evidence.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }) else { throw ToolArgumentError("evidence must contain at most 100 nonempty IDs, each at most 200 characters.") }
        guard Set(proposal.evidence).count == proposal.evidence.count else { throw ToolArgumentError("evidence contains duplicate IDs; use distinct IDs from the reflection.") }
        guard proposal.trigger.apps.count <= 100, proposal.trigger.apps.allSatisfy(JournalAppName.isBundleID) else { throw ToolArgumentError("trigger.apps must resolve to at most 100 bundle IDs; use app names shown in the reflection or bundle IDs.") }
        guard proposal.trigger.state.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }) ?? true else { throw ToolArgumentError("trigger.state must contain 1–200 characters or be omitted.") }
        if let time = proposal.trigger.time {
            guard (0..<1440).contains(time.startMinute), (0..<1440).contains(time.endMinute) else { throw ToolArgumentError("trigger.time startMinute and endMinute must be local minutes after midnight from 0 to 1439 (07:45 = 465).") }
            guard time.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw ToolArgumentError("trigger.time.weekdays must contain integers 1–7 (1 = Sunday).") }
        }
    }

}

/// Accept valid entries in input order, with one atomic write and one review group.
@MainActor protocol PartialRulesProposing {
    func proposePartially(_ proposals: [RuleProposal], at now: Date) throws -> [Result<LearnedRule, any Error>]
}
