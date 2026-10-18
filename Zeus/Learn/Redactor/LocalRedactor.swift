import Foundation
import NaturalLanguage
import AppKit
import Synchronization

struct PrivateSpan: Sendable {
    let range: NSRange
    let kind: RedactionKind
}
struct ProsePrivateSpan: Sendable {
    let text: String
    let kind: RedactionKind
}
/// Model input is already pattern/name redacted. A test double must never log that input.
protocol ProseRedacting: Sendable {
    func spans(in text: String) async -> [ProsePrivateSpan]?
}

/// All processing is local. The semantic pass can only replace exact substrings of the first pass.
actor LocalRedactor: Redactor {
    private let prose: (any ProseRedacting)?
    init(useOnDeviceModel: Bool = true) { prose = useOnDeviceModel ? OnDeviceProseRedactor.shared : nil }
    init(prose: (any ProseRedacting)?) { self.prose = prose }
    func redact(_ text: String) async -> Redacted<String> {
        // Bounded, fail-closed handling for accidental megabyte documents; never truncate and retain a raw tail.
        guard text.utf8.count <= 128_000 else {
            return .init(RedactionKind.secret.placeholder, report: .init(counts: [.secret: 1]))
        }
        let first = Self.firstPass(text)
        guard !Task.isCancelled, let prose, let found = await prose.spans(in: first.value) else { return first }
        return Self.addProse(found, to: first)
    }
    nonisolated private static func addProse(_ found: [ProsePrivateSpan], to first: Redacted<String>) -> Redacted<String> {
        var spans: [PrivateSpan] = []
        let ns = first.value as NSString
        for candidate in found {
            let quote = candidate.text
            guard quote.count >= 3, !quote.contains("‹"), !quote.contains("›"),
                  !["secret", "password", "token", "bearer"].contains(quote.lowercased()),
                  [.name, .health, .finance, .secret].contains(candidate.kind) else { continue }
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let range = ns.range(of: quote, options: [], range: search)
                guard range.location != NSNotFound else { break }
                spans.append(.init(range: range, kind: candidate.kind))
                search = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
            }
        }
        let second = Self.replace(first.value, spans: spans)
        var report = first.report; report.semanticEngine = .onDeviceModel
        for (kind, count) in second.report.counts { report.counts[kind, default: 0] += count }
        return .init(second.value, report: report)
    }
    /// Batch user-content values only; system facts and schema keys never enter either redaction pass.
    func redact(_ payload: JournalPayload) async -> Redacted<JournalPayload> {
        let keys = payload.details.keys.filter { !JournalPayload.systemDetailKeys.contains($0) }.sorted()
        var strings = [payload.description]
        if let text = payload.text { strings.append(text) }
        if let topic = payload.topic { strings.append(topic) }
        for key in keys { strings.append(payload.details[key] ?? "") }
        var safe = strings.map { value in
            value.utf8.count <= 128_000 ? Self.firstPass(value) : .init("‹secret›", report: .init(counts: [.secret: 1]))
        }
        if safe.contains(where: { !$0.value.isEmpty }), !Task.isCancelled, let prose,
           let spans = await prose.spans(in: safe.map(\.value).joined(separator: "\n")) {
            safe = safe.map { Self.addProse(spans, to: $0) }
        }
        let topicIndex = payload.text == nil ? 1 : 2
        var offset = topicIndex + (payload.topic == nil ? 0 : 1), details = payload.details
        for key in keys { details[key] = safe[offset].value; offset += 1 }
        var report = RedactionReport()
        for value in safe {
            for (kind, count) in value.report.counts { report.counts[kind, default: 0] += count }
            if value.report.semanticEngine == .onDeviceModel { report.semanticEngine = .onDeviceModel }
            else if report.semanticEngine == .patternsOnly { report.semanticEngine = value.report.semanticEngine }
        }
        return .init(.init(description: safe[0].value, text: payload.text == nil ? nil : safe[1].value,
                           topic: payload.topic == nil ? nil : safe[topicIndex].value, details: details), report: report)
    }
    /// Fast always-available pass, also used for synthetic precision/recall tests.
    nonisolated static func firstPass(_ text: String) -> Redacted<String> {
        var spans = patternSpans(text)
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, !isNonNameFact(String(text[range])) {
                spans.append(.init(range: NSRange(range, in: text), kind: .name))
            }
            return true
        }
        let result = replace(text, spans: spans)
        var report = result.report; report.semanticEngine = .naturalLanguage
        return .init(result.value, report: report)
    }
    /// Name tagging can mistake clock values, durations and calendar vocabulary for people.
    nonisolated static func isNonNameFact(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendarWords: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "mon", "tue", "wed", "thu", "fri", "sat", "sun", "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december", "jan", "feb", "mar", "apr", "jun",
            "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
        if calendarWords.contains(value) { return true }
        return value.range(of: #"^(?:[0-9]+|[0-9]{1,2}:[0-9]{2}(?:[–—-][0-9]{1,2}:[0-9]{2})?|(?:[0-9]+\s*(?:h|hr|hours?|min|minutes?|seconds?|sec)\s*)+)$"#,
                           options: .regularExpression) != nil
    }
    nonisolated static func patternSpans(_ text: String) -> [PrivateSpan] {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let ns = text as NSString
        var spans: [PrivateSpan] = []
        func add(_ pattern: String, _ kind: RedactionKind, capture: Int = 0,
                 accept: (String) -> Bool = { _ in true }) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: full) {
                let range = match.range(at: capture)
                guard range.location != NSNotFound, range.length > 0, accept(ns.substring(with: range)) else { continue }
                spans.append(.init(range: range, kind: kind))
            }
        }
        add(#"(?s)-----BEGIN (?:[A-Z0-9 ]*PRIVATE KEY)-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#, .secret)
        add(#"(?i)\b(?:password|pwd|secret|token|bearer)\b\s*(?::|=|is\b)?\s*[\"']?([^\r\n]+)"#, .secret, capture: 1)
        add(#"(?i)[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}](?:[\p{L}\p{N}.-]*[\p{L}\p{N}])?\.[\p{L}]{2,}"#, .email)
        add(#"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#, .identity)
        add(#"(?i)\b(?:otp|2fa|verification code|authentication code|one.time (?:code|password)|pin)\s*(?:is|:|=)?\s*([0-9][0-9 -]{3,12}[0-9])\b"#, .secret, capture: 1)
        add(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, .card, accept: luhn)
        if let regex = try? NSRegularExpression(pattern: #"\b[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,45}\b"#) {
            let lengths = ["GB": 22, "DE": 22, "FR": 27, "ES": 24, "NL": 18, "IT": 27, "CH": 21, "AT": 20,
                           "BE": 16, "IE": 22, "PT": 25, "GR": 27, "PL": 28, "CZ": 24, "SK": 24, "SE": 24,
                           "NO": 15, "DK": 18, "FI": 18, "LU": 20, "RO": 24, "BG": 22, "HR": 21, "SI": 19]
            for match in regex.matches(in: text, range: full) {
                let candidate = ns.substring(with: match.range)
                let expected = lengths[String(candidate.prefix(2))]
                var compact = "", sourceLength = 0
                for char in candidate {
                    sourceLength += char.utf16.count
                    if char != " " { compact.append(char) }
                    guard expected.map({ compact.count == $0 }) ?? ((15...34).contains(compact.count)) else { continue }
                    if validIBAN(compact) {
                        spans.append(.init(range: NSRange(location: match.range.location, length: sourceLength), kind: .iban)); break
                    }
                    if let expected, compact.count >= expected { break }
                }
            }
        }
        add(#"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{15,}|github_pat_[A-Za-z0-9_]{15,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#, .secret)
        add(#"\b[A-Za-z0-9_+/=-]{28,}\b"#, .secret) { candidate in
            guard candidate.contains(where: \.isNumber), candidate.contains(where: \.isLetter),
                  !candidate.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return false }
            let counts = Dictionary(grouping: candidate, by: { $0 }).mapValues(\.count)
            let n = Double(candidate.count)
            return counts.values.reduce(0.0) { $0 - (Double($1)/n) * log2(Double($1)/n) } >= 4.2
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
                                             NSTextCheckingResult.CheckingType.address.rawValue) {
            for match in detector.matches(in: text, range: full) {
                spans.append(.init(range: match.range, kind: match.resultType == .address ? .address : .phone))
            }
        }
        return spans
    }
    nonisolated static func luhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        return digits.reversed().enumerated().reduce(0) { sum, pair in
            let value = pair.offset % 2 == 1 ? pair.element * 2 : pair.element
            return sum + (value > 9 ? value - 9 : value)
        } % 10 == 0
    }
    nonisolated private static func validIBAN(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(compact.count) else { return false }
        let rotated = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for char in rotated {
            guard let scalar = char.asciiValue else { return false }
            let value = scalar >= 65 ? Int(scalar) - 55 : Int(scalar) - 48
            remainder = (remainder * (value >= 10 ? 100 : 10) + value) % 97
        }
        return remainder == 1
    }
    nonisolated static func replace(_ text: String, spans: [PrivateSpan]) -> Redacted<String> {
        let ns = text as NSString
        let ordered = spans.filter { $0.range.location >= 0 && $0.range.length > 0 && NSMaxRange($0.range) <= ns.length }
            .sorted { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var merged: [PrivateSpan] = []
        for span in ordered {
            if let last = merged.last, NSIntersectionRange(last.range, span.range).length > 0 {
                merged[merged.count - 1] = .init(range: NSUnionRange(last.range, span.range),
                    kind: last.range.length >= span.range.length ? last.kind : span.kind)
            } else { merged.append(span) }
        }
        let output = NSMutableString(string: text); var report = RedactionReport()
        for span in merged.reversed() {
            output.replaceCharacters(in: span.range, with: span.kind.placeholder)
            report.counts[span.kind, default: 0] += 1
        }
        return .init(output as String, report: report)
    }
}

/// Repairs only an app identity field, never redacted prose, titles or document paths.
enum JournalAppName {
    private static let installed = Mutex<[String: String]>([:])

    static func displayName(_ item: JournalItem, resolve: (String) -> String? = installedName) -> String {
        let details = item.payload.value.details
        if let name = [details["name"], details["appName"]].compactMap({ $0 }).first(where: usable) { return name }
        guard let bundleID = item.app, !bundleID.isEmpty else { return "Unknown app" }
        if let name = resolve(bundleID), usable(name) { return name }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    static func repairedDetails(_ item: JournalItem) -> [String: String] {
        var details = item.payload.value.details
        guard item.app != nil else { return details }
        for key in ["name", "appName"] where details[key].map({ !usable($0) }) == true {
            details[key] = displayName(item)
        }
        return details
    }

    private static func usable(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("‹")
    }

    private static func installedName(_ identifier: String) -> String? {
        installed.withLock { cache in
            if let name = cache[identifier] { return name.isEmpty ? nil : name }
            // LaunchServices lookup reads app bundle metadata only; it never opens the app or its documents.
            let url = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).first
            let bundle = url.flatMap(Bundle.init(url:))
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            cache[identifier] = name ?? ""
            return name
        }
    }
}
