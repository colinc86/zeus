import Foundation
import ZeusProtocol

/// Only a visible screen is accepted. History text alone is never proof of a live dialog.
struct ManagedPaneSnapshot: Sendable {
    var screen: String
    var inputMetadata: String
    var plainLines: [String] {
        screen.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
    }
}

/// Conservative, version-tested terminal signatures. Modal controls take precedence over spinners.
enum ManagedPaneClassifier {
    enum Classification: Equatable, Sendable {
        case blocked(reason: String, dialog: String)
        case working, idle, unknown
    }
    static func classify(_ snapshot: ManagedPaneSnapshot, agent: AgentKind) -> Classification {
        let input = TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8))
        let allLines = snapshot.plainLines
        let codexApproval = agent == .codex && allLines.contains { $0.contains("Would you like to run the following command?") }
            && allLines.contains {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("› ") && line.dropFirst(2).first?.isNumber == true
            }
            && allLines.contains { $0.contains("No, and tell Codex") && $0.contains("(esc)") }
            && (allLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.contains("Press enter to confirm") == true)
        // Codex keeps a live editor while working, with its actual work indicator
        // above it. Models, shortcuts, warnings and any other footer content below
        // that composer must never determine readiness. Full-screen dialogs still
        // use their entire capture when the cursor is outside an editable composer.
        // The highlighted numbered approval row can use the same › glyph as an
        // editor. A complete approval widget is a dialog even when its cursor sits
        // on that row; ordinary composer/footer variants still follow M7's rule.
        let lines = agent == .codex && !codexApproval ? input?.codexInputStart.map { Array(allLines.prefix($0)) } ?? allLines : allLines
        let text = lines.joined(separator: "\n").lowercased()
        let lastLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.lowercased() ?? ""
        let footer = lines.suffix(12).joined(separator: "\n").lowercased()
        func dialog(_ marker: String, controls: Bool) -> Classification? {
            guard controls, let index = lines.lastIndex(where: { $0.lowercased().contains(marker) }) else { return nil }
            var start = index
            if agent == .claude, marker == "do you want to proceed?", let title = lines[..<index].lastIndex(where: {
                ["Bash command", "Edit file", "Create file", "Read file"].contains($0.trimmingCharacters(in: .whitespaces))
            }), index - title < 20 { start = title }
            let excerpt = lines[start...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(5).joined(separator: "\n")
            let firstLine = lines[start].trimmingCharacters(in: .whitespaces)
            // A terminal wraps long prose mid-sentence. Keep the full first line
            // when it is a title; prefer a complete leading sentence for prose.
            let reason: String
            if let end = firstLine.firstIndex(where: { $0 == "?" || $0 == "!" || $0 == "." }),
               firstLine.distance(from: firstLine.startIndex, to: end) >= 20 {
                reason = String(firstLine[...end])
            } else { reason = firstLine }
            return .blocked(reason: reason, dialog: excerpt)
        }
        switch agent {
        case .claude:
            if let blocked = dialog("warning: loading development channels", controls:
                footer.contains("❯ 1. i am using this for local development") && footer.contains("2. exit")) { return blocked }
            for marker in ["select login method:", "choose the text style", "quick safety check:", "warning: claude code running in bypass", "do you want to use this api key?", "do you want to proceed?"] {
                let controls = text.contains("❯ ") && (lastLine.contains("enter to confirm") || lastLine.contains("esc to cancel") || (marker == "select login method:" && text.contains("anthropic console")))
                if let blocked = dialog(marker, controls: controls) { return blocked }
            }
        case .codex:
            if let blocked = dialog("would you like to run the following command?", controls: lastLine.contains("press enter to confirm") && footer.contains("no, and tell codex")) { return blocked }
            if let blocked = dialog("welcome to codex", controls: text.contains("sign in with device code") && lastLine.contains("press enter to continue")) { return blocked }
            if let blocked = dialog("trust", controls: footer.contains("yes") && footer.contains("no") && footer.contains("confirm")) { return blocked }
        case .opencode:
            // OpenCode overlays this centered modal above an otherwise idle
            // composer; its controls are not in the bottom terminal footer.
            if let blocked = dialog("update available", controls: lines.contains(where: {
                $0.lowercased().contains("update available") && $0.lowercased().contains("esc")
            }) && lines.contains(where: {
                $0.lowercased().contains("skip") && $0.lowercased().contains("confirm")
            }) && text.contains("update now?")) { return blocked }
            if let blocked = dialog("permission required", controls: footer.contains("allow once") && footer.contains("reject") && footer.contains("enter confirm")) { return blocked }
            if let blocked = dialog("connect a provider", controls: text.contains("search") && text.contains("providers") && lines.contains(where: { $0.lowercased().contains("connect a provider") && $0.lowercased().contains("esc") })) { return blocked }
            if let blocked = dialog("question", controls: footer.contains("confirm") && footer.contains("select")) { return blocked }
        case .other: return .unknown
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !(agent == .codex && input?.codexInputStart != nil) { return .unknown }
        if footer.contains("esc to interrupt") || footer.contains("esc interrupt") { return .working }
        if input?.isProbablyIdle == true { return .idle }
        return .unknown
    }
}
