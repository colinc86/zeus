import Darwin
import xlocale
import Foundation
import ZeusLink
import ZeusProtocol

enum TmuxPasteRecoveryError: Error, LocalizedError {
    case absent
    var errorDescription: String? { "Zeus's saved paste is no longer in Terminal. It was not pasted again." }
}

/// Shared discovery for managed launch, Settings and per-attempt tmux delivery.
enum TmuxExecutable {
    static var paths: [String] { searchPaths(environment: ProcessInfo.processInfo.environment) }
    static func searchPaths(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let directories = [home + "/.local/bin", home + "/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/run/current-system/sw/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("tmux").path }
    }
    static func resolve(paths: [String]? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        (paths ?? searchPaths(environment: environment)).first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

/// Shared envelope for text-injection transports. Multiline text keeps its line breaks.
enum AgentInjectionText {
    static func format(_ delivery: Delivery) -> String {
        let card = delivery.cardID.map { " card_id=" + $0 } ?? ""
        let normalized = MessageText.preservingLines(delivery.content)
        let multiline = delivery.content.utf8.contains(10)
        let content = multiline ? normalized : delivery.content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "[zeus delivery_id=\(delivery.id)\(card)] \(content) (call zeus_ack with this delivery_id)"
    }
}

/// Conservative text snapshot of the active terminal input. Unknown prompts,
/// unknown hidden cursors and multiline drafts stay queued rather than being submitted.
struct TmuxInputSnapshot: Equatable, Sendable {
    let lines: [String]
    let x: Int
    let y: Int
    let width: Int
    let cursorVisible: Bool
    /// Newer tmux reports the mode. Older releases return no field; only the
    /// known, live composers verified by our real-CLI fixtures may use that fallback.
    let bracketedPaste: Bool?
    private let mutedBody: [Bool]
    init?(metadata: Data, screen: Data) {
        let fields = String(decoding: metadata, as: UTF8.self).trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false)
        guard (5...6).contains(fields.count), let x = Int(fields[0]), let y = Int(fields[1]), let width = Int(fields[2]),
              fields[3] == "0", ["0", "1"].contains(fields[4]), x >= 0, y >= 0, width > 0 else { return nil }
        if fields.count == 6, !["", "0", "1"].contains(fields[5]) { return nil }
        let rawLines = String(decoding: screen, as: UTF8.self).components(separatedBy: "\n")
        let decoded = rawLines.map(Self.decodeLine)
        lines = decoded.map { $0.0 }; mutedBody = decoded.map { $0.1 }
        guard lines.indices.contains(y) else { return nil }
        self.x = x; self.y = y; self.width = width; cursorVisible = fields[4] == "1"
        bracketedPaste = fields.count == 6 && !fields[5].isEmpty ? fields[5] == "1" : nil
        // Claude draws its own inverse-video caret and hides the hardware cursor.
        // Only its positively bounded composer may use that logical cursor.
        guard cursorVisible || claudeInputStart != nil else { return nil }
    }
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "─" }
    }
    private var claudeInputRows: Range<Int>? {
        let rules = lines.indices.filter { Self.isRule(lines[$0]) }
        for pair in zip(rules, rules.dropFirst()).reversed() {
            let rows = (pair.0 + 1)..<pair.1
            if rows.contains(y), lines[rows.lowerBound].hasPrefix("❯ ") { return rows }
        }
        return nil
    }
    /// A cursor-bound Claude composer; content below its upper rule is editor/footer chrome.
    var claudeInputStart: Int? { claudeInputRows?.lowerBound }
    /// Codex's prompt, indented continuation rows and blank separator bound the
    /// composer. Nothing below that separator is consulted, including footer
    /// models, shortcuts, warnings or other text.
    /// The blank separator and model footer distinguish live input from history.
    private var codexInputRows: Range<Int>? {
        guard let start = lines[..<(y + 1)].lastIndex(where: { $0.hasPrefix("› ") }) else { return nil }
        // The model footer bounds blank lines inside the live composer, including
        // when the user moves the caret above a blank line. Prefer the last footer
        // so a quoted prompt/footer in the body cannot redefine this boundary.
        if let footer = lines.indices.reversed().first(where: {
            $0 >= max(0, lines.count - 4) && $0 > start + 1
                && lines[$0].hasPrefix("  ") && !lines[$0].hasPrefix("   ") && lines[$0].contains(" · ")
                && lines[$0 - 1].trimmingCharacters(in: .whitespaces).isEmpty
        }), footer > start + 1, lines[footer - 1].trimmingCharacters(in: .whitespaces).isEmpty,
           (start..<(footer - 1)).contains(y),
           ((start + 1)..<(footer - 1)).allSatisfy({ lines[$0].hasPrefix("  ") || lines[$0].isEmpty }) {
            return start..<(footer - 1)
        }
        var end = start + 1
        while lines.indices.contains(end), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
            guard lines[end].hasPrefix("  ") else { return nil }
            end += 1
        }
        guard (start..<end).contains(y), lines.indices.contains(end) else { return nil }
        return start..<end
    }
    /// Activity/dialog classification excludes the separate footer whenever a
    /// live Codex composer is present. Full-screen dialogs have no such cursor.
    var codexInputStart: Int? { codexInputRows?.lowerBound }
    /// Match the full live Codex composer, permitting footer repaint and caret
    /// movement but never an added or edited input row.
    func containsOnlyCodexPaste(_ text: String) -> Bool {
        guard let rows = codexInputRows else { return false }
        return containsWrappedParagraph(text, rows: rows, firstPrefix: "› ", columns: width - 4)
    }
    /// tmux capture -e retains SGR attributes. A dim placeholder differs from
    /// a human draft with the same text and its cursor moved to the beginning.
    private static func decodeLine(_ raw: String) -> (String, Bool) {
        let scalars = Array(raw.unicodeScalars)
        var i = 0, dim = false, grey = false, inverse = false, plain = ""
        var attributes: [(muted: Bool, inverse: Bool)] = []
        while i < scalars.count {
            if scalars[i].value == 27, i + 1 < scalars.count, scalars[i + 1] == "[" {
                var end = i + 2
                while end < scalars.count && !(64...126).contains(scalars[end].value) { end += 1 }
                if end < scalars.count {
                    if scalars[end] == "m" {
                        let codes = String(String.UnicodeScalarView(scalars[(i + 2)..<end])).split(separator: ";").compactMap { Int($0) }
                        if codes.isEmpty { dim = false; grey = false; inverse = false }
                        var index = 0
                        while index < codes.count {
                            let code = codes[index]
                            if [38, 48, 58].contains(code), index + 1 < codes.count {
                                if code == 38 {
                                    grey = false
                                    if codes[index + 1] == 5, index + 2 < codes.count {
                                        // OpenCode renders genuine input in 255 (near-white).
                                        // It is not evidence of a suggestion, even at Home.
                                        grey = (232...250).contains(codes[index + 2])
                                    } else if codes[index + 1] == 2, index + 4 < codes.count {
                                        let r = codes[index + 2], g = codes[index + 3], b = codes[index + 4]
                                        grey = r == g && g == b && (90...190).contains(r)
                                    }
                                }
                                index += codes[index + 1] == 2 ? 5 : 3; continue
                            }
                            if code == 0 { dim = false; grey = false; inverse = false }
                            if code == 22 { dim = false }
                            if code == 2 { dim = true }
                            if code == 7 { inverse = true }
                            if code == 27 { inverse = false }
                            if code == 90 { grey = true }
                            if (30...37).contains(code) || (91...97).contains(code) || code == 39 { grey = false }
                            index += 1
                        }
                    }
                    i = end + 1; continue
                }
            }
            let promptSpace = scalars[i] == "\u{00a0}" && (plain.last == "❯" || plain.last == "›")
            let scalar: Unicode.Scalar = promptSpace ? " " : scalars[i]; plain.unicodeScalars.append(scalar)
            attributes.append((dim || grey, inverse))
            i += 1
        }
        let prefix: Int
        if plain.hasPrefix("❯ ") || plain.hasPrefix("› ") { prefix = 2 }
        else if let border = plain.firstIndex(of: "┃"), plain[..<border].allSatisfy({ $0 == " " }) {
            prefix = plain.distance(from: plain.startIndex, to: border) + 3
        }
        else if plain.hasPrefix("  ") { prefix = 2 }
        else { return (plain, false) }
        var allMuted = true, mutedCount = 0
        for (index, scalar) in plain.unicodeScalars.enumerated() where index >= prefix && !CharacterSet.whitespaces.contains(scalar) {
            let style = attributes[index]
            // Claude paints its software caret over the first suggestion glyph
            // without dim styling. The rest must be positively muted; a normal
            // human draft moved Home and a one-glyph caret alone never qualify.
            if plain.hasPrefix("❯ "), index == prefix, style.inverse { continue }
            allMuted = allMuted && style.muted; mutedCount += 1
        }
        return (plain, mutedCount > 0 && allMuted)
    }
    private var openCodeBoxStart: Int? {
        guard lines.indices.contains(y + 2), lines[y].hasPrefix("  ┃"),
              lines[(y + 1)...].prefix(4).contains(where: { $0.hasPrefix("  ┃  ") && $0.contains(" · ") }),
              lines.suffix(4).contains(where: { $0.hasPrefix("  ╹") }),
              lines.suffix(4).contains(where: { $0.contains("ctrl+p commands") }) else { return nil }
        var row = y
        while row > 0 && lines[row - 1].hasPrefix("  ┃") { row -= 1 }
        return row
    }
    private var openCodeComposer: Bool { x == 5 && openCodeBoxStart != nil }
    /// Cursor-bound conversation editor; history is strictly above its box.
    /// The centered home editor has no completed conversation to inspect.
    var openCodeInputStart: Int? { openCodeBoxStart }
    /// OpenCode centers its home-screen editor. Only use its complete native box
    /// and command row to identify drafts; this does not authorize paste or Enter.
    private var centeredOpenCodeDraft: String? {
        let indent = lines[y].prefix(while: { $0 == " " }).count
        guard indent > 2, cursorVisible, x >= indent + 3,
              lines[y].dropFirst(indent).hasPrefix("┃"),
              let border = lines.indices.first(where: { $0 > y && lines[$0].hasPrefix(String(repeating: " ", count: indent) + "╹") }),
              lines[(border + 1)...].prefix(3).contains(where: { $0.contains("ctrl+p commands") }),
              let mode = lines.indices.last(where: { $0 > y && $0 < border && lines[$0].hasPrefix(String(repeating: " ", count: indent) + "┃  ") && lines[$0].contains(" · ") }) else { return nil }
        let prefix = String(repeating: " ", count: indent) + "┃"
        var start = y
        while start > 0 && lines[start - 1].hasPrefix(prefix) { start -= 1 }
        guard (start..<mode).allSatisfy({ lines[$0].hasPrefix(prefix) }) else { return nil }
        let text = lines[start..<mode].map { String($0.dropFirst(indent + 3)).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if x == indent + 3, (start..<mode).allSatisfy({
            lines[$0].dropFirst(indent + 3).trimmingCharacters(in: .whitespaces).isEmpty || mutedBody[$0]
        }) { return nil }
        return text.isEmpty ? nil : text
    }
    /// Only a positively bounded composer can report a human draft. Suggestions
    /// are empty; dialogs and work are rejected separately by the pane classifier.
    var humanDraftText: String? {
        guard !isEmpty else { return nil }
        let text: String
        if let rows = claudeInputRows ?? codexInputRows {
            text = rows.map { String(lines[$0].dropFirst(2)) }.joined(separator: "\n")
        } else if let start = openCodeBoxStart,
                  let end = lines.indices.last(where: { $0 > y && lines[$0].hasPrefix("  ┃  ") && lines[$0].contains(" · ") }) {
            let columns = lines.suffix(4).first(where: { $0.hasPrefix("  ╹") })?
                .prefix(while: { $0 == " " || $0 == "╹" || $0 == "▀" || $0 == "━" }).count ?? width
            text = lines[start..<end].map { String($0.prefix(columns).dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        } else if let draft = centeredOpenCodeDraft { text = draft }
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private var prompt: String? {
        if openCodeComposer { return String(lines[y].prefix(x)).padding(toLength: x, withPad: " ", startingAt: 0) }
        let line = lines[y]
        let leading = String(line.prefix { $0 == " " })
        let body = line.dropFirst(leading.count)
        return body.hasPrefix("› ") || body.hasPrefix("❯ ") ? leading + String(body.prefix(2)) : nil
    }
    /// A bounded composer means the agent is idle even with unsent text. This
    /// includes Zeus's own paste during the monitor's paste/Enter race. Delivery
    /// separately requires emptiness or an exact match to the recorded paste.
    var isProbablyIdle: Bool {
        claudeInputStart != nil || codexInputRows != nil || openCodeBoxStart != nil || centeredOpenCodeDraft != nil || isEmpty || (prompt != nil && x == prompt?.count && lines[y].contains("› ") && Self.placeholders.contains(String(lines[y].dropFirst(x)).trimmingCharacters(in: .whitespaces)))
    }
    private static let placeholders: Set<String> = ["Ask Codex to do anything", "Write tests for @filename", "Find and fix a bug in @filename", "Explain this codebase", "Implement {feature}", "Improve documentation in @filename", "Summarize recent commits", "Run /review on my current changes"]
    var isEmpty: Bool {
        // An entirely blank fresh terminal supports simple stdin agents/test sinks.
        if x == 0 && lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return true }
        guard let prompt, x == prompt.count else { return false }
        if openCodeComposer {
            // The current input row and contiguous preceding box rows must be blank.
            guard lines[y].dropFirst(x).trimmingCharacters(in: .whitespaces).isEmpty || mutedBody[y] else { return false }
            var row = y - 1
            while row >= 0, lines[row].hasPrefix("  ┃") {
                guard lines[row].dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty || mutedBody[row] else { return false }
                row -= 1
            }
            // A caret moved Home can sit above another genuine input row. Check
            // the remaining input padding too, excluding a wide TUI's sidebar.
            let borderColumns = lines.suffix(4).first(where: { $0.hasPrefix("  ╹") })?
                .prefix(while: { $0 == " " || $0 == "╹" || $0 == "▀" || $0 == "━" }).count ?? width
            row = y + 1
            while lines.indices.contains(row), lines[row].hasPrefix("  ┃"), !lines[row].contains(" · ") {
                guard lines[row].prefix(borderColumns).dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty || mutedBody[row] else { return false }
                row += 1
            }
            return true
        }
        let body = String(lines[y].dropFirst(prompt.count)).trimmingCharacters(in: .whitespaces)
        // Placeholder wording can change; the CLI's muted styling and caret at
        // the start distinguish it from deliberately typed text moved Home.
        if lines[y].contains("› ") {
            guard mutedBody[y] else { return false }
            return codexInputRows?.dropFirst().allSatisfy { mutedBody[$0] } ?? true
        }

        if let rows = claudeInputRows, y == rows.lowerBound, mutedBody[y] {
            return rows.dropFirst().allSatisfy { row in
                lines[row].trimmingCharacters(in: .whitespaces).isEmpty || (lines[row].hasPrefix("  ") && mutedBody[row])
            }
        }

        // Claude's bottom rule bounds the complete composer. A blank first line
        // of a multiline draft must never be confused with an empty input.
        guard body.isEmpty, lines.indices.contains(y + 1) else { return false }
        let rule = lines[y + 1].trimmingCharacters(in: .whitespaces)
        return rule.count >= 3 && rule.allSatisfy { $0 == "─" }
    }
    /// tmux cursor positions count cells; emoji and combining text count differently from Swift characters.
    static func cellWidth(_ text: String) -> Int {
        // The GUI process often has the C locale, where wcwidth reports -1 for
        // printable Unicode. Scope UTF-8 to this synchronous call's thread,
        // restore it on return, and never change the process/global locale.
        let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)
        let previous = locale.map { uselocale($0) }
        defer {
            if let previous { uselocale(previous) }
            if let locale { freelocale(locale) }
        }
        return text.reduce(0) { total, character in
            let emoji = character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
            let cells = character.unicodeScalars.map { scalar in
                let width = Int(wcwidth(Int32(scalar.value)))
                if width >= 0 { return width }
                // Unsupported printable characters must never count as zero.
                switch scalar.properties.generalCategory {
                case .nonspacingMark, .enclosingMark, .format: return 0
                default: return 2
                }
            }.max() ?? 0
            return total + (emoji ? max(2, cells) : cells)
        }
    }
    /// Refuse a paste before mutation when it can scroll its beginning out of
    /// the visible capture. Verification must compare the complete envelope.
    var acceptsMultilinePaste: Bool {
        bracketedPaste != false && (claudeInputRows != nil || codexInputRows != nil || openCodeComposer)
    }
    func canVerifyPaste(_ text: String) -> Bool {
        if text.contains("\n") {
            guard acceptsMultilinePaste else { return false }
            let available: Int, columns: Int
            if let rows = claudeInputRows { available = rows.lowerBound - 2; columns = width - 4 }
            else if let rows = codexInputRows { available = rows.lowerBound - 2; columns = width - 4 }
            else if openCodeComposer {
                // OpenCode 1.18's default textarea is capped at a third of the
                // pane (at least six rows), even when there is space above it.
                // A custom smaller cap is still caught by exact post-paste verification.
                available = min(y - 2, max(6, (lines.count - 1) / 3)); columns = width - 8
            }
            else { return false }
            // Word wrapping can leave unused cells. Count every explicit (including blank) line.
            let count = text.components(separatedBy: "\n").reduce(0) { total, line in
                var rows = 1, used = 0
                for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                    let cells = Self.cellWidth(String(word))
                    if used > 0 && used + 1 + cells > max(1, columns) { rows += 1; used = 0 }
                    if used > 0 { used += 1 }
                    used += cells
                    if used > 0 { rows += (used - 1) / max(1, columns); used = (used - 1) % max(1, columns) + 1 }
                }
                return total + rows
            }
            return count <= available
        }
        if openCodeComposer {
            let available = max(0, y - 2), columns = max(1, width - 8)
            var rows = 1, used = 0
            for word in text.split(separator: " ") {
                let cells = Self.cellWidth(String(word))
                if used > 0 && used + 1 + cells > columns { rows += 1; used = 0 }
                if used > 0 { used += 1 }
                used += cells
                rows += max(0, (used - 1) / columns); used = (used - 1) % columns + 1
            }
            return rows <= available
        }
        // Reserve a cell per wrap for wide graphemes at the right margin.
        return Self.cellWidth(text) + x < max(0, lines.count - y) * max(1, width - 1)
    }
    /// Claude's rules bound its complete input. Custom statusline output below the
    /// bottom rule is not input and may repaint while Zeus verifies a paste.
    func containsOnlyClaudePaste(_ text: String) -> Bool {
        guard let rows = claudeInputRows else { return false }
        // Claude can reserve a right-hand input inset as well as the prompt.
        // Keep compatibility with wider wrapped captures too.
        // Match the complete paragraph at either observed width; never infer
        // a human edit solely because Claude wrapped a word one row earlier.
        return containsWrappedParagraph(text, rows: rows, firstPrefix: "❯ ", columns: width - 4)
            || containsWrappedParagraph(text, rows: rows, firstPrefix: "❯ ", columns: width - 2)
    }
    private func containsWrappedParagraph(_ text: String, rows: Range<Int>, firstPrefix: String, columns: Int) -> Bool {
        let start = rows.lowerBound, end = rows.upperBound - 1
        var remaining = text[...]
        let columns = max(1, columns)
        for row in start...end {
            let prefix = row == start ? firstPrefix : "  "
            guard lines[row].hasPrefix(prefix) || (row != start && lines[row].isEmpty && remaining.first == "\n") else { return false }
            var body = String(lines[row].dropFirst(2))
            if row == end, y == end, !cursorVisible, body.hasSuffix(" "), Self.cellWidth(lines[row]) == x + 1 { body.removeLast() }
            guard remaining.hasPrefix(body), !body.isEmpty || remaining.first == "\n" else { return false }
            remaining = remaining.dropFirst(body.count)
            if row != end {
                // capture-pane omits spaces at the right of a logical line.
                // Consume them only at an explicit LF; never skip body text.
                let endSpaces = remaining.prefix { $0 == " " }.count
                if remaining.dropFirst(endSpaces).first == "\n" { remaining = remaining.dropFirst(endSpaces + 1); continue }
                let gap = columns - Self.cellWidth(body)
                guard gap >= 0 else { return false }
                if remaining.first == " " {
                    remaining = remaining.dropFirst()
                    let nextWord = String(remaining.prefix { $0 != " " && $0 != "\n" })
                    // Claude may wrap a next word that exactly reaches the input edge.
                    // Its bytes still have to match the entire remaining paragraph.
                    guard 1 + Self.cellWidth(nextWord) >= gap else { return false }
                } else {
                    // A long word can wrap at a cell boundary instead.
                    guard gap == 0 || (gap == 1 && remaining.first.map { Self.cellWidth(String($0)) == 2 } == true) else { return false }
                }
            }
        }
        return remaining.isEmpty
    }
    /// Verify only the text we pasted is present, including wrapped lines. Extra
    /// human input prevents Enter. Claude submits the complete bounded paragraph
    /// regardless of its caret position; Codex's known composer is also bounded.
    func containsOnlyPaste(_ text: String, after before: TmuxInputSnapshot, freshOwnedAgent: AgentKind? = nil) -> Bool {
        // An opaque label isn't proof of bytes or delivery identity. It may be
        // accepted only during the fresh, journaled empty->owned-paste operation.
        // Recovery never enables this path: a human could have replaced the hidden payload.
        if let agent = freshOwnedAgent, before.isEmpty, before.bracketedPaste != false, bracketedPaste != false,
           containsFreshPasteLabel(text, agent: agent, before: before) { return true }
        if before.openCodeComposer, let start = openCodeBoxStart {
            // OpenCode word-wraps its box upward while the cursor stays near the bottom.
            // Compare every visible input row to the exact paragraph, consuming only
            // spaces dropped at a wrap boundary. Hidden paste-summary tokens fail.
            guard start < y, lines[start].dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty,
                  Array(lines.dropFirst(y + 1)) == Array(before.lines.dropFirst(before.y + 1)) else { return false }
            var remaining = text[...]
            for row in (start + 1)...y {
                guard lines[row].hasPrefix("  ┃  ") else { return false }
                let body = String(lines[row].dropFirst(5)).replacingOccurrences(of: " +$", with: "", options: .regularExpression)
                guard remaining.hasPrefix(body), !body.isEmpty || remaining.first == "\n" else { return false }
                remaining = remaining.dropFirst(body.count)
                if row < y {
                    let endSpaces = remaining.prefix { $0 == " " }.count
                    if remaining.dropFirst(endSpaces).first == "\n" { remaining = remaining.dropFirst(endSpaces + 1) }
                    else { remaining = remaining.drop(while: { $0 == " " }) }
                }
                else if x != 5 + Self.cellWidth(body) { return false }
            }
            return remaining.isEmpty
        }
        if before.claudeInputStart != nil { return containsOnlyClaudePaste(text) }
        if codexInputRows != nil { return containsOnlyCodexPaste(text) }
        guard y >= before.y, lines.indices.contains(before.y) else { return false }
        let prefix = before.prompt ?? ""
        let expected = prefix + text
        var remaining = expected[...]
        for line in lines[before.y..<y] {
            guard remaining.hasPrefix(line) else { return false }
            remaining = remaining.dropFirst(line.count)
            let gap = width - Self.cellWidth(line)
            guard gap >= 0 else { return false }
            // capture-pane strips trailing blanks. Consume real pasted spaces,
            // but not the empty cell where a two-cell grapheme wrapped early.
            if gap == 1, let first = remaining.first, Self.cellWidth(String(first)) == 2 { continue }
            let spaces = String(repeating: " ", count: gap)
            guard remaining.hasPrefix(spaces) else { return false }
            remaining = remaining.dropFirst(gap)
        }
        func suffix(_ value: TmuxInputSnapshot) -> [String] {
            var lines = Array(value.lines.dropFirst(value.y + 1))
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return lines
        }
        return remaining == lines[y] && suffix(self) == suffix(before)
    }

    private func containsFreshPasteLabel(_ text: String, agent: AgentKind, before: TmuxInputSnapshot) -> Bool {
        guard text.contains("\n") else { return false }
        switch agent {
        case .claude:
            guard before.claudeInputRows != nil, let rows = claudeInputRows, rows.count == 1 else { return false }
            var body = String(lines[rows.lowerBound].dropFirst(2))
            if !cursorVisible, body.hasSuffix(" "), Self.cellWidth(lines[y]) == x + 1 { body.removeLast() }
            let prefix = "[Pasted text #", suffix = " +\(text.filter { $0 == "\n" }.count) lines]"
            guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return false }
            let number = body.dropFirst(prefix.count).dropLast(suffix.count)
            return !number.isEmpty && number.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        case .codex:
            guard before.codexInputRows != nil, let rows = codexInputRows, rows.count == 1 else { return false }
            // Codex counts Unicode scalars (Rust chars), not UTF-8 bytes or graphemes.
            let label = "[Pasted Content \(text.unicodeScalars.count) chars]"
            return String(lines[rows.lowerBound].dropFirst(2)) == label && x == 2 + Self.cellWidth(label)
        case .opencode:
            guard before.openCodeComposer, let start = openCodeBoxStart, start + 1 == y,
                  lines[start].dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty,
                  Array(lines.dropFirst(y + 1)) == Array(before.lines.dropFirst(before.y + 1)) else { return false }
            let label = "[Pasted ~\(text.components(separatedBy: "\n").count) lines]"
            return lines[y].hasPrefix("  ┃  ") && lines[y].dropFirst(5).trimmingCharacters(in: .whitespaces) == label
                && x == 5 + Self.cellWidth(label) + 1 // OpenCode inserts a space after the virtual paste token.
        case .other: return false
        }
    }
}

/// Retains the original snapshot while a paste has no submission receipt. Durable
/// runtime metadata also permits known composer recovery across a Zeus relaunch.
@MainActor
private final class PendingTmuxPastes {
    struct Paste { let deliveryID: String; let before: TmuxInputSnapshot }
    var values: [String: Paste] = [:]
}

/// Literal tmux paste, then Enter. Each delivery owns its named buffer; concurrent
/// deliveries cannot replace each other's input. No agent text becomes a shell argument.
@MainActor
struct TmuxConnector: DeliveryConnector {
    private let resolveExecutable: @MainActor () -> URL?
    private let runner: any ProcessRunning
    private let gate = ConnectorSendGate()
    private let pastes = PendingTmuxPastes()
    /// Production resolves on each send so installing tmux repairs a running app.
    init(runner: any ProcessRunning = FoundationProcessRunner()) {
        self.init(executableResolver: { TmuxExecutable.resolve() }, runner: runner)
    }
    /// An explicit executable (including nil) remains fixed for deterministic tests.
    init(executable: URL?, runner: any ProcessRunning = FoundationProcessRunner()) {
        self.init(executableResolver: { executable }, runner: runner)
    }
    init(executableResolver: @escaping @MainActor () -> URL?, runner: any ProcessRunning = FoundationProcessRunner()) {
        self.resolveExecutable = executableResolver; self.runner = runner
    }
    var isAvailable: Bool { resolveExecutable() != nil }
    /// Local readiness for Retry: a pane and its namespace must agree, and the
    /// executable must exist. Actual draft/permission checks happen before typing.
    func canRetryDelivery(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool {
        guard isAvailable, target(session, routing: routing) != nil else { return false }
        let socket = bridge?.hello.tmuxSocketPath ?? (routing as? DeliveryRoutingContext)?.tmuxSocketPath ?? session.tmuxSocketPath
        if bridge?.hello.tmuxPane != nil && socket == nil { return false }
        let configured = routing.assistantSessionKey == nil || routing.assistantSessionKey == session.sessionKey
        if configured, routing.tmuxTarget != nil {
            guard let selected = (routing as? any TmuxTargetRouting)?.tmuxTargetSocketPath,
                  let socket, selected.hasPrefix("/"), socket.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: selected).resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: socket).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return true
    }
    private func target(_ session: ConnectedSession, routing: any AgentRoutingSettings) -> String? {
        // Replies to another session use that bridge's pane, not the assistant's pane.
        let configured = routing.assistantSessionKey == nil || routing.assistantSessionKey == session.sessionKey
        let value = configured ? (routing.tmuxTarget ?? session.tmuxPane) : session.tmuxPane
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    func canDeliver(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool {
        routing.deliveryMethod == .tmux && target(session, routing: routing) != nil
    }
    func deliver(_ delivery: Delivery, to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) async throws {
        guard let executable = resolveExecutable() else { throw ConnectorError.missingTmux }
        guard let target = target(session, routing: routing) else { throw ConnectorError.missingTarget }
        let socket = bridge?.hello.tmuxSocketPath ?? (routing as? DeliveryRoutingContext)?.tmuxSocketPath ?? session.tmuxSocketPath
        // A live bridge's pane ID is not globally unique. Old metadata must never
        // silently address an identically numbered pane in the GUI's default server.
        if bridge?.hello.tmuxPane != nil && socket == nil { throw ConnectorError.missingTmuxSocket }
        func validateTarget() throws {
            // The picker/manual override belongs to the assistant only; replies retain
            // their originating bridge's pane and namespace.
            let configured = routing.assistantSessionKey == nil || routing.assistantSessionKey == session.sessionKey
            guard self.target(session, routing: routing) == target else { throw ConnectorError.mismatchedTmuxSocket }
            if configured, routing.tmuxTarget != nil {
                guard let selected = (routing as? any TmuxTargetRouting)?.tmuxTargetSocketPath,
                      let socket, selected.hasPrefix("/"), socket.hasPrefix("/") else { throw ConnectorError.mismatchedTmuxSocket }
                let normalize: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
                guard normalize(selected) == normalize(socket) else { throw ConnectorError.mismatchedTmuxSocket }
            }
        }
        try validateTarget() // Reject before acquiring/loading any paste buffer.
        let namespace = ["-u"] + (socket.map { ["-S", $0] } ?? [])
        // Persist the terminal namespace, independent of CLI symlink/install path.
        let destination = (socket.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } ?? "default") + ":" + target
        try await gate.acquire(destination)
        defer { gate.release(destination) }
        let buffer = "zeus-" + delivery.id
        var loaded = false
        func command(_ args: [String], input: Data? = nil) async throws {
            try Task.checkCancellation()
            try validateTarget()
            let result = try await runner.run(executable: executable, arguments: namespace + args, input: input)
            guard result.status == 0 else { throw ConnectorError.processExit(result.status) }
        }
        func snapshot() async throws -> TmuxInputSnapshot {
            try Task.checkCancellation()
            try validateTarget() // Settings may change while subprocess I/O is suspended.
            try await (routing as? DeliveryRoutingContext)?.managedValidateDestination?()
            let metadata = try await runner.run(executable: executable, arguments: namespace + ["display-message", "-p", "-t", target, "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}|#{bracket_paste_flag}"], input: nil)
            let screen = try await runner.run(executable: executable, arguments: namespace + ["capture-pane", "-p", "-e", "-t", target], input: nil)
            try Task.checkCancellation()
            guard metadata.status == 0, screen.status == 0 else { throw ConnectorError.processExit(metadata.status != 0 ? metadata.status : screen.status) }
            if let context = routing as? DeliveryRoutingContext, let allowed = context.managedInputAllowed {
                guard allowed() else { throw ConnectorError.inputBusy }
                let classificationMetadata = String(decoding: metadata.stdout, as: UTF8.self).trimmingCharacters(in: .newlines).components(separatedBy: "|").prefix(5).joined(separator: "|")
                let classification = ManagedPaneClassifier.classify(.init(screen: String(decoding: screen.stdout, as: UTF8.self), inputMetadata: classificationMetadata), agent: session.agent)
                if case .blocked = classification { throw ConnectorError.inputBusy }
                if classification == .working { throw ConnectorError.inputBusy }
                // After our own paste, the nonempty composer is expected; draft guards still apply.
            }
            guard let value = TmuxInputSnapshot(metadata: metadata.stdout, screen: screen.stdout) else { throw ConnectorError.inputBusy }
            return value
        }
        let text = AgentInjectionText.format(delivery)
        let context = routing as? DeliveryRoutingContext
        func submitted(didSubmit: Bool = false) throws {
            pastes.values.removeValue(forKey: destination)
            context?.didSubmitRecordedTmuxPaste = didSubmit
            try context?.confirmTmuxPaste?(nil)
        }
        do {
            let initial = try await snapshot()
            let pending = pastes.values[destination]
            let recovering = pending?.deliveryID == delivery.id || delivery.meta["tmux_paste_destination"] == destination
            if context?.onlySubmitRecordedTmuxPaste == true {
                guard delivery.meta["tmux_paste_destination"] == destination else { throw ConnectorError.mismatchedTmuxSocket }
                if initial.isEmpty {
                    try submitted()
                    throw TmuxPasteRecoveryError.absent
                }
            }
            if recovering, !initial.isEmpty {
                let matches = pending.map { initial.containsOnlyPaste(text, after: $0.before) }
                    ?? (initial.containsOnlyClaudePaste(text) || initial.containsOnlyCodexPaste(text))
                guard matches else { throw ConnectorError.inputChanged }
                try await command(["send-keys", "-t", target, "Enter"])
                try submitted(didSubmit: true)
                return
            }
            if pending != nil, !initial.isEmpty { throw ConnectorError.inputBusy }
            guard initial.isEmpty else { throw ConnectorError.inputBusy }
            if pending != nil || recovering { try submitted() }
            if text.contains("\n"), !initial.acceptsMultilinePaste { throw ConnectorError.inputBusy }
            guard initial.canVerifyPaste(text) else { throw ConnectorError.inputTooLong }
            try await command(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8))
            loaded = true
            let before = try await snapshot()
            guard before.isEmpty else { throw ConnectorError.inputBusy }
            if text.contains("\n"), !before.acceptsMultilinePaste { throw ConnectorError.inputBusy }
            guard before.canVerifyPaste(text) else { throw ConnectorError.inputTooLong }
            // Save ownership before any mutation. A lost completion or cancelled
            // verifier must never turn our own paragraph into a human draft.
            try context?.confirmTmuxPaste?(destination)
            context?.didMutateTmuxInput = true
            pastes.values[destination] = .init(deliveryID: delivery.id, before: before)
            try await command(["paste-buffer", "-p"] + (text.contains("\n") ? ["-r"] : []) + ["-d", "-b", buffer, "-t", target])
            loaded = false
            let deadline = ContinuousClock.now + .milliseconds(500)
            while !(try await snapshot().containsOnlyPaste(text, after: before, freshOwnedAgent: session.agent)) {
                guard ContinuousClock.now < deadline else { throw ConnectorError.inputChanged }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await command(["send-keys", "-t", target, "Enter"])
            try submitted(didSubmit: true)
        } catch {
            if loaded {
                // Cleanup must run even when the parent send was cancelled.
                let runner = self.runner
                _ = await Task.detached {
                    try? await runner.run(executable: executable, arguments: namespace + ["delete-buffer", "-b", buffer], input: nil)
                }.value
            }
            throw error
        }
    }
}
