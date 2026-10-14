import CryptoKit
import Foundation
import ZeusProtocol

/// A visible managed-agent question. Only a clicked listed option can authorize input.
struct ManagedAgentPrompt: Equatable, Sendable {
    enum Kind: String, Sendable { case command, edit, other }
    struct Option: Identifiable, Equatable, Sendable {
        enum Key: Equatable, Sendable {
            enum Shortcut: String, Sendable { case yes = "y", always = "p", cancel = "Escape" }
            case digit(Int)
            case shortcut(Shortcut)
            /// OpenCode's horizontal button index, selected with arrows and Enter.
            case horizontal(Int)
        }
        let id: String
        let label: String
        let key: Key
    }
    let kind: Kind
    let title: String
    let detail: String
    let question: String
    let options: [Option]
    /// Includes dialog content and the controller/pane lifetime, not cursor/highlight/history.
    let fingerprint: String
    /// Verified from OpenCode's highlighted button, never assumed to be its default.
    let highlightedOption: Int?
}

enum ManagedPromptAnswerResult: Equatable, Sendable {
    case answered(optionID: String, label: String)
    case changed
    /// Keystrokes were sent once, but a clear/changed screen could not be confirmed.
    case unconfirmed(label: String)
    var message: String {
        switch self {
        case .answered(_, let label): "You chose \(label)."
        case .changed: "This question changed. Open Terminal to answer it."
        case .unconfirmed: "Zeus couldn't confirm your choice. Open Terminal to check it."
        }
    }
}

/// Optional app-facing capability, source-compatible with existing managed-session fakes.
/// Appdev may display the question/detail/options and await the result for its chosen caption.
@MainActor
protocol ManagedPromptAnswering: AnyObject {
    var managedPrompt: ManagedAgentPrompt? { get }
    /// No free-text or arbitrary-key API. IDs must still belong to this exact fingerprint.
    func answerManagedPrompt(fingerprint: String, optionID: String) async -> ManagedPromptAnswerResult
}

extension ManagedPromptAnswering {
    var managedPrompt: ManagedAgentPrompt? { nil }
    func answerManagedPrompt(fingerprint: String, optionID: String) async -> ManagedPromptAnswerResult { .changed }
}

/// Conservative version-tested permission dialogs. Unknown prompts stay Terminal-only.
enum ManagedPromptParser {
    static func parse(_ snapshot: ManagedPaneSnapshot, agent: AgentKind, scope: String = "") -> ManagedAgentPrompt? {
        guard case .blocked(let reason, let dialog) = ManagedPaneClassifier.classify(snapshot, agent: agent) else { return nil }
        let rawLines = snapshot.plainLines
        let lines = rawLines.map(clean)
        func identity(_ range: Range<Int>) -> String {
            // Keep command whitespace in the identity even though UI chrome is
            // cleaned for presentation. Indentation inside quoted code matters.
            rawLines[range].filter { !isRule(clean($0)) && !clean($0).hasPrefix("Tip:") }.joined(separator: "\n")
        }
        func make(_ kind: ManagedAgentPrompt.Kind, _ title: String, _ detail: String, _ question: String,
                  _ options: [ManagedAgentPrompt.Option], highlighted: Int? = nil, context: String = "") -> ManagedAgentPrompt {
            let fields = [scope, agent.rawValue, kind.rawValue, title, detail, question, context]
                + options.flatMap { [$0.id, $0.label, String(describing: $0.key)] }
            let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return .init(kind: kind, title: title, detail: detail, question: question,
                         options: options, fingerprint: fingerprint, highlightedOption: highlighted)
        }
        switch agent {
        case .claude:
            if let question = lines.lastIndex(of: "Do you want to proceed?"),
               let title = lines[..<question].lastIndex(where: { ["Bash command", "Edit file", "Create file", "Read file"].contains($0) }),
               lines.filter({ !$0.isEmpty }).suffix(4).contains(where: { $0.contains("Esc to cancel") }) {
                let body = Array(lines[(title + 1)..<question])
                let rules = body.indices.filter { isRule(body[$0]) }
                let detail: String
                if let first = rules.first, let last = rules.last, first < last {
                    detail = cleanedDetail(Array(body[(first + 1)..<last]))
                } else { detail = cleanedDetail(body) }
                let options = numberedOptions(Array(lines[(question + 1)...]), claude: true)
                if !detail.isEmpty, !options.isEmpty {
                    return make(lines[title] == "Bash command" ? .command : .edit, lines[title], detail, lines[question], options,
                                context: identity((title + 1)..<question))
                }
            }
        case .codex:
            if let question = lines.lastIndex(of: "Would you like to run the following command?"),
               let command = lines[(question + 1)...].firstIndex(where: { $0.hasPrefix("$ ") }),
               let firstOption = lines[(command + 1)...].firstIndex(where: { numbered($0) != nil }) {
                var detail = Array(lines[command..<firstOption]); detail[0] = String(detail[0].dropFirst(2))
                let options = numberedOptions(Array(lines[firstOption...]), claude: false)
                if !options.isEmpty {
                    return make(.command, "Command", cleanedDetail(detail), lines[question], options,
                                context: identity((question + 1)..<firstOption))
                }
            }
        case .opencode:
            if let start = lines.lastIndex(where: { $0.contains("Permission required") }),
               let optionRow = lines[(start + 1)...].firstIndex(where: { $0.contains("Allow once") && $0.contains("Allow always") && $0.contains("Reject") }),
               let highlighted = openCodeHighlight(snapshot.screen.components(separatedBy: "\n")[optionRow]) {
                let body = Array(lines[(start + 1)..<optionRow])
                let title = body.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? "Permission required"
                let commandIndex = body.firstIndex(where: { $0.hasPrefix("$ ") })
                var detail = commandIndex.map { Array(body[$0...]) } ?? body.filter { !$0.hasPrefix("# ") }
                if commandIndex != nil, !detail.isEmpty { detail[0] = String(detail[0].dropFirst(2)) }
                let options = ["Allow once", "Allow always", "Reject"].enumerated().map {
                    ManagedAgentPrompt.Option(id: ["once", "always", "reject"][$0.offset], label: $0.element, key: .horizontal($0.offset))
                }
                return make(commandIndex == nil ? (title.lowercased().contains("edit") ? .edit : .other) : .command,
                            title, cleanedDetail(detail), "Allow this request?", options, highlighted: highlighted,
                            context: identity((start + 1)..<optionRow))
            }
        case .other: return nil
        }
        let title = clean(reason)
        return make(.other, title.isEmpty ? "Agent question" : title,
                    cleanedDetail(dialog.components(separatedBy: "\n").filter { clean($0) != title }),
                    "Open Terminal to answer this question.", [])
    }
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "^\\s*[┃│║] ?", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    private static func isRule(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { "─━╌┄┅┈┉╭╮╰╯┌┐└┘▀╹─ ".contains($0) }
    }
    private static func cleanedDetail(_ lines: [String]) -> String {
        lines.map(clean).filter { !$0.isEmpty && !isRule($0) && !$0.hasPrefix("Tip:")
            && !$0.contains("Esc to cancel") && !$0.contains("enter confirm")
            && !$0.contains("ctrl+f fullscreen") && !$0.contains("Press enter to confirm")
            && !$0.hasPrefix("This command requires approval") && !$0.hasPrefix("/permissions ") }
            .joined(separator: "\n")
    }
    private static func numbered(_ line: String) -> (Int, String)? {
        let value = line.replacingOccurrences(of: "^[❯›]\\s*", with: "", options: .regularExpression)
        guard let dot = value.firstIndex(of: "."), let digit = Int(value[..<dot]), (1...9).contains(digit) else { return nil }
        let label = value[value.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (digit, label)
    }
    private static func numberedOptions(_ lines: [String], claude: Bool) -> [ManagedAgentPrompt.Option] {
        var numberedLabels: [(Int, String)] = []
        for line in lines {
            if line.contains("Esc to cancel") || line.contains("Press enter to confirm") { break }
            if let value = numbered(line) { numberedLabels.append(value) }
            else if !line.isEmpty, !numberedLabels.isEmpty {
                let index = numberedLabels.count - 1
                numberedLabels[index].1 += "\n" + line
            }
        }
        guard numberedLabels.map(\.0) == Array(1...max(1, numberedLabels.count)) else { return [] }
        var result: [ManagedAgentPrompt.Option] = []
        for (digit, label) in numberedLabels {
            if claude { result.append(.init(id: String(digit), label: label, key: .digit(digit))) }
            else {
                let shortcut: ManagedAgentPrompt.Option.Key.Shortcut
                if label.hasSuffix("(y)") { shortcut = .yes }
                else if label.hasSuffix("(p)") { shortcut = .always }
                else if label.hasSuffix("(esc)") { shortcut = .cancel }
                else { return [] }
                result.append(.init(id: shortcut.rawValue, label: label, key: .shortcut(shortcut)))
            }
        }
        return result
    }
    /// Exactly one button must have a distinct background/inverse style. Plain or
    /// ambiguous captures cannot authorize navigation from an assumed default.
    private static func openCodeHighlight(_ raw: String) -> Int? {
        var plain = "", styles: [String] = [], background = "default", inverse = false
        let pattern = try? NSRegularExpression(pattern: "\\x1b\\[[0-?]*[ -/]*[@-~]")
        let source = raw as NSString
        var position = 0
        func append(_ segment: String) {
            plain += segment
            styles += segment.map { _ in background + (inverse ? ":inverse" : "") }
        }
        for match in pattern?.matches(in: raw, range: NSRange(location: 0, length: source.length)) ?? [] {
            append(source.substring(with: NSRange(location: position, length: match.range.location - position)))
            let code = source.substring(with: match.range)
            if code.hasSuffix("m") {
                let values = code.dropFirst(2).dropLast().split(separator: ";").compactMap { Int($0) }
                if values.isEmpty { background = "default"; inverse = false }
                var index = 0
                while index < values.count {
                    let value = values[index]
                    if value == 0 { background = "default"; inverse = false }
                    else if value == 7 { inverse = true }
                    else if value == 27 { inverse = false }
                    else if value == 49 { background = "default" }
                    else if (40...47).contains(value) || (100...107).contains(value) { background = String(value) }
                    else if [38, 48, 58].contains(value), index + 1 < values.count {
                        let count = values[index + 1] == 2 ? 5 : 3
                        guard index + count <= values.count else { return nil }
                        if value == 48 { background = values[index..<(index + count)].map(String.init).joined(separator: ";") }
                        index += count; continue
                    }
                    index += 1
                }
            }
            position = NSMaxRange(match.range)
        }
        append(source.substring(from: position))
        var buttons: [String] = []
        for label in ["Allow once", "Allow always", "Reject"] {
            guard let range = plain.range(of: label) else { return nil }
            let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let stop = plain.distance(from: plain.startIndex, to: range.upperBound)
            let selected = Array(styles[start..<stop])
            guard let style = selected.first, selected.allSatisfy({ $0 == style }) else { return nil }
            buttons.append(style)
        }
        return buttons.indices.first { index in buttons.indices.filter { $0 != index }.allSatisfy { buttons[$0] != buttons[index] }
            && Set(buttons.indices.filter { $0 != index }.map { buttons[$0] }).count == 1 }
    }
}
