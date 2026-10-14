import Foundation
import ZeusProtocol

/// Native completed-turn evidence for a specific Zeus input. Footer repaint,
/// a new user echo, and unsent composer text cannot complete another delivery.
/// This deliberately recognizes only the installed, recorded TUI signatures.
enum ManagedTurnCompletion {
    static func deliveryID(in snapshot: ManagedPaneSnapshot, agent: AgentKind) -> String? {
        guard let input = TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8)) else { return nil }
        let start: Int?, prefix: String, completed: (String) -> Bool
        switch agent {
        case .codex:
            start = input.codexInputStart; prefix = "› "
            completed = { $0.range(of: "^  Worked for (?:<)?[0-9].* • [0-9]", options: .regularExpression) != nil }
        case .opencode:
            start = input.openCodeInputStart; prefix = "  ┃  "
            completed = { $0.range(of: "^     ▣  [^\\n]+ · [^\\n]+ · [0-9]+(?:\\.[0-9]+)?(?:ms|s|m)\\s*$", options: .regularExpression) != nil }
        case .claude, .other: return nil
        }
        guard let start else { return nil }
        let history = Array(snapshot.plainLines.prefix(start))
        let marker = "[zeus delivery_id="
        guard let user = history.lastIndex(where: { $0.hasPrefix(prefix + marker) }),
              history[(user + 1)...].contains(where: completed) else { return nil }
        let body = history[user].dropFirst(prefix.count + marker.count)
        guard let closing = body.firstIndex(of: "]"),
              let id = body[..<closing].split(whereSeparator: \.isWhitespace).first else { return nil }
        return String(id)
    }
}
