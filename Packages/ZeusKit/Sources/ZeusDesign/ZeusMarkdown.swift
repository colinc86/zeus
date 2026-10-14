import Synchronization
import SwiftUI

/// Markdown for card bodies, styled for the Zeus fonts (CONVERSATION.md §1 "Type").
///
/// Departure Mono has a single weight, so in `.pixel` **strong** runs take the title accent (gold) instead
/// of a bold face and *emphasis* takes the secondary text color; `.system` keeps real bold and italic.
/// Inline `code` gets a subtle background tint in both. Links pass through unchanged.
///
/// Block markdown (F9) is flattened into the same single `AttributedString`, so one `Text` still shows it:
/// the typewriter, line limits and measuring work exactly as for inline text, and a line limit counts
/// rendered lines. Headings become bold lines, list items get "•" / "–" / "1." markers with nested indents,
/// quotes get a "▌" bar in the secondary color, fenced code becomes a tinted block that keeps its lines,
/// tables become "│"-separated rows, and rules a short line. Line breaks inside a paragraph are kept, as
/// agents expect. Text without any block syntax keeps the exact inline behavior (whitespace preserved).
/// Decorations (markers, bars, code padding) carry `ZeusMarkdown.DecorationAttribute`, so
/// `spokenText(_:)` can leave them out of an accessibility label.
///
/// Results are cached (bounded, per palette and font choice), so re-evaluating a view body doesn't re-parse the same message (P8 #4).
public enum ZeusMarkdown {
    /// Parses inline markdown (whitespace preserved) and applies Zeus emphasis styling.
    /// Falls back to the plain text if the markdown doesn't parse.
    public static func attributed(_ markdown: String, choice: ZeusFontChoice, palette: ZeusPalette) -> AttributedString {
        // Every palette `\.zeusPalette` produces (light, dark and their Increase Contrast variants) is a built-in,
        // keyed by its index: comparing is cheap, hashing 24 `Color`s isn't. Any other palette is keyed by its colors.
        let key = CacheKey(markdown: markdown, choice: choice, palette: palette)
        if let hit = cache.withLock({ $0.value(for: key) }) { return hit }
        let styled = style(markdown, choice: choice, palette: palette)
        cache.withLock { $0.insert(styled, for: key) }
        return styled
    }

    static func style(_ markdown: String, choice: ZeusFontChoice, palette: ZeusPalette) -> AttributedString {
        var text = hasBlockSyntax(markdown) ? blocks(markdown, palette: palette) : inline(markdown)
        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized), choice == .pixel {
                text[run.range].foregroundColor = palette.title
            } else if intent.contains(.emphasized), choice == .pixel, run.foregroundColor == nil {
                // The pixel font has no italic: emphasis would otherwise vanish.
                text[run.range].foregroundColor = palette.secondaryText
            }
            if intent.contains(.code) {
                text[run.range].backgroundColor = palette.secondaryFill
            }
        }
        linkify(&text, palette: palette)
        return text
    }

    /// Bare `http(s)://`, `file://` and `mailto:` addresses become links (agents rarely write markdown links), and every
    /// link run is shown as one: accent color and underlined. Addresses inside code spans stay plain text.
    static func linkify(_ text: inout AttributedString, palette: ZeusPalette) {
        var additions: [(Range<AttributedString.Index>, URL)] = []
        for run in text.runs where run.link == nil && run.inlinePresentationIntent?.contains(.code) != true && run[DecorationAttribute.self] == nil {
            let slice = text[run.range]
            let string = String(slice.characters)
            for match in string.matches(of: Self.urlPattern) {
                let range = match.range
                var candidate = String(string[range])
                // Trailing punctuation belongs to the sentence, not the address.
                while let last = candidate.last, ".,;:!?)]}>\"'".contains(last) {
                    if last == ")" && candidate.filter({ $0 == "(" }).count >= candidate.filter({ $0 == ")" }).count { break }
                    candidate.removeLast()
                }
                guard !candidate.isEmpty, let url = URL(string: candidate) else { continue }
                let lower = slice.characters.index(slice.startIndex, offsetBy: string.distance(from: string.startIndex, to: range.lowerBound))
                let upper = slice.characters.index(lower, offsetBy: candidate.count)
                additions.append((lower..<upper, url))
            }
        }
        for (range, url) in additions { text[range].link = url }
        for run in text.runs where run.link != nil {
            text[run.range].foregroundColor = palette.accent
            text[run.range].underlineStyle = .single
        }
    }

    /// Built per call: `Regex` isn't Sendable, so it can't be a shared constant under strict concurrency.
    private static var urlPattern: Regex<Substring> { /(?:https?:\/\/|file:\/\/|mailto:)[^\s<>]+/.ignoresCase() }

    /// The text for an accessibility label: the rendered characters without decorations
    /// (quote bars, code padding, bullet glyphs), so VoiceOver reads only the content.
    public static func spokenText(_ text: AttributedString) -> String {
        var spoken = ""
        for run in text.runs where run[DecorationAttribute.self] == nil {
            spoken += String(text[run.range].characters)
        }
        return spoken
    }

    /// A whole message as VoiceOver should read it (A4N-5): the visible words of `markdown`, without heading or
    /// emphasis markers, quote bars or link destinations, one sentence per line of text. Use it wherever an
    /// accessibility label names a card body, so the label says what the bubble shows.
    public static func spokenText(markdown: String) -> String {
        let lines = spokenText(attributed(markdown, choice: .system, palette: .light))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.enumerated().map { index, line in
            let last = index == lines.count - 1
            guard !last, let end = line.last, !".!?:…".contains(end) else { return line }
            return line + "."
        }.joined(separator: " ")
    }

    /// Marks characters that are presentation only (markers, bars, padding).
    public enum DecorationAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "ZeusMarkdownDecoration"
    }

    // MARK: Parsing

    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    /// Whether any line starts a markdown block other than a plain paragraph.
    static func hasBlockSyntax(_ markdown: String) -> Bool {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            line.wholeMatch(of: blockLine) != nil
        }
    }
    nonisolated(unsafe) private static let blockLine =
        /\s{0,3}(?:#{1,6}(?:\s.*)?|[-*+]\s+\S.*|\d{1,9}[.)]\s+\S.*|>.*|```.*|~~~.*|(?:[-*_]\s*){3,}|\|.*\|\s*)/

    /// Keeps single line breaks inside paragraphs (CommonMark would fold them into spaces) by making each a
    /// hard break. Fenced code is left alone; trailing spaces at the end of a block are ignored by the parser.
    static func preservingLineBreaks(_ markdown: String) -> String {
        var inFence = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return String(line) }
            if inFence || line.allSatisfy(\.isWhitespace) || line.hasSuffix("  ") { return String(line) }
            return line + "  "
        }.joined(separator: "\n")
    }

    private typealias Kind = PresentationIntent.Kind

    private static func blocks(_ markdown: String, palette: ZeusPalette) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: preservingLineBreaks(markdown),
                                                 options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        else { return inline(markdown) }
        var out = AttributedString()
        var previous: [PresentationIntent.IntentType] = []
        var markedItem: Int?
        var tableRow: Int?
        func decoration(_ string: String, color: Color? = nil) -> AttributedString {
            var piece = AttributedString(string)
            piece[DecorationAttribute.self] = true
            if let color { piece.foregroundColor = color }
            return piece
        }
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var content = AttributedString(parsed[range])
            content.presentationIntent = nil

            // Table cells on one row join with a bar; a new row starts a new line.
            if let row = components.first(where: { if case .tableRow = $0.kind { true } else { $0.kind == .tableHeaderRow } }) {
                if row.identity == tableRow {
                    out += decoration(" │ ", color: palette.secondaryText) + content
                    continue
                }
                tableRow = row.identity
                if components.contains(where: { $0.kind == .tableHeaderRow }) { content = emphasized(content) }
            } else { tableRow = nil }

            if !previous.isEmpty { out += AttributedString(separator(after: previous, before: components)) }
            previous = components

            // Prefix, from the outermost container in.
            var prefix = AttributedString()
            let outermostFirst = Array(components.reversed())
            let itemDepth = components.filter { if case .listItem = $0.kind { true } else { false } }.count
            var seenItems = 0
            for (index, component) in outermostFirst.enumerated() {
                switch component.kind {
                case .blockQuote:
                    prefix += decoration("▌ ", color: palette.secondaryText)
                case .listItem(let ordinal):
                    seenItems += 1
                    let ordered = index > 0 && outermostFirst[index - 1].kind == .orderedList
                    let marker = ordered ? "\(ordinal). " : (seenItems == 1 ? "• " : "– ")
                    if seenItems < itemDepth { prefix += decoration(String(repeating: " ", count: 2)); continue }
                    if markedItem == component.identity {
                        prefix += decoration(String(repeating: " ", count: marker.count))
                    } else {
                        markedItem = component.identity
                        prefix += decoration(marker, color: palette.secondaryText)
                    }
                default: break
                }
            }
            let inQuote = components.contains { $0.kind == .blockQuote }

            if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
                out += codeBlock(String(content.characters), prefix: prefix)
                continue
            }
            if components.contains(where: { $0.kind == .thematicBreak }) {
                out += prefix + decoration(String(repeating: "─", count: 12), color: palette.secondaryText)
                continue
            }
            if components.contains(where: { if case .header = $0.kind { true } else { false } }) {
                content = emphasized(content)
            }
            if inQuote {
                for run in content.runs where run.foregroundColor == nil && run.inlinePresentationIntent?.contains(.stronglyEmphasized) != true {
                    content[run.range].foregroundColor = palette.secondaryText
                }
            }
            // Continuation lines of a hard break keep the block's indent.
            out += prefix + indentingBreaks(content, prefix: prefix)
        }
        return out
    }

    /// One newline between items of the same list, rows of a table, paragraphs of a quote, and after a
    /// heading; a blank line between other blocks.
    private static func separator(after previous: [PresentationIntent.IntentType], before next: [PresentationIntent.IntentType]) -> String {
        func container(_ components: [PresentationIntent.IntentType]) -> Int? {
            components.last { [.unorderedList, .orderedList, .blockQuote].contains($0.kind) || isTable($0.kind) }?.identity
        }
        if previous.contains(where: { if case .header = $0.kind { true } else { false } }) { return "\n" }
        if let a = container(previous), a == container(next) { return "\n" }
        return "\n\n"
    }

    private static func isTable(_ kind: Kind) -> Bool { if case .table = kind { true } else { false } }

    private static func emphasized(_ content: AttributedString) -> AttributedString {
        var content = content
        for run in content.runs {
            content[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
        }
        return content
    }

    private static func indentingBreaks(_ content: AttributedString, prefix: AttributedString) -> AttributedString {
        guard !prefix.characters.isEmpty, content.characters.contains("\n") else { return content }
        // Continuation lines keep quote bars but not list markers.
        var indent = AttributedString()
        for run in prefix.runs {
            let piece = prefix[run.range]
            indent += String(piece.characters).hasPrefix("▌") ? AttributedString(piece)
                : AttributedString(String(repeating: " ", count: piece.characters.count))
        }
        indent[DecorationAttribute.self] = true
        var result = AttributedString()
        var lineStart = content.startIndex
        var index = content.startIndex
        while index < content.endIndex {
            let next = content.characters.index(after: index)
            if content.characters[index] == "\n" {
                result += AttributedString(content[lineStart..<next]) + indent
                lineStart = next
            }
            index = next
        }
        result += AttributedString(content[lineStart..<content.endIndex])
        return result
    }

    /// Fenced code keeps its lines; short blocks are padded to one width so the tint reads as a block.
    static let codePaddingLimit = 36
    private static func codeBlock(_ code: String, prefix: AttributedString) -> AttributedString {
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.isEmpty { lines = [""] }
        let width = min(lines.map(\.count).max() ?? 0, codePaddingLimit)
        var indent = AttributedString(String(repeating: " ", count: prefix.characters.count))
        indent[DecorationAttribute.self] = true
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") + indent } else { out += prefix }
            var leading = AttributedString(" "); leading[DecorationAttribute.self] = true
            var trailing = AttributedString(String(repeating: " ", count: max(0, width - line.count) + 1))
            trailing[DecorationAttribute.self] = true
            var body = AttributedString(line)
            body.inlinePresentationIntent = .code
            leading.inlinePresentationIntent = .code
            trailing.inlinePresentationIntent = .code
            out += leading + body + trailing
        }
        return out
    }

    struct CacheKey: Hashable {
        enum Palette: Hashable { case builtIn(Int), custom(ZeusPalette) }
        let markdown: String
        let choice: ZeusFontChoice
        let palette: Palette

        init(markdown: String, choice: ZeusFontChoice, palette: ZeusPalette) {
            self.markdown = markdown
            self.choice = choice
            self.palette = ZeusPalette.builtIn.firstIndex(of: palette).map { .builtIn($0) } ?? .custom(palette)
        }
    }

    /// Two generations of `capacity` entries: when the recent one fills it becomes the older one, and a hit in
    /// the older one moves back to recent. Messages on screen stay cached while a long thread scrolls, instead
    /// of the whole cache being dropped every `capacity` new messages.
    struct Cache {
        var recent: [CacheKey: AttributedString] = [:]
        var older: [CacheKey: AttributedString] = [:]

        mutating func value(for key: CacheKey) -> AttributedString? {
            if let hit = recent[key] { return hit }
            guard let hit = older.removeValue(forKey: key) else { return nil }
            insert(hit, for: key)
            return hit
        }

        mutating func insert(_ value: AttributedString, for key: CacheKey) {
            if recent.count >= cacheCapacity { older = recent; recent = [:] }
            recent[key] = value
        }

        var count: Int { recent.count + older.count }
        func contains(_ key: CacheKey) -> Bool { recent[key] != nil || older[key] != nil }
    }
    /// Entries per generation (the cache holds at most twice this).
    static let cacheCapacity = 256
    static let cache = Mutex(Cache())
}

/// A markdown body styled with `ZeusMarkdown`, reading the font choice and color scheme from the environment.
public struct ZeusMarkdownText: View {
    public var markdown: String
    @Environment(\.zeusFontChoice) private var choice
    @Environment(\.zeusPalette) private var palette

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        Text(ZeusMarkdown.attributed(markdown, choice: choice, palette: palette))
    }
}
