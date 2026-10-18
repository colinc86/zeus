import Foundation

struct RedactedTypingRun: Sendable {
    let app: Redacted<String>
    let words: Redacted<String>
    let wordCount: Int
}
protocol TypingRunRedacting: Sendable {
    func redact(words: Redacted<String>, app: String) async -> RedactedTypingRun?
}
/// Stage one happens before deferral; stage two MUST succeed on typed words or nothing is kept.
actor RunRedactor: TypingRunRedacting {
    private let redactor: any Redactor
    init(redactor: any Redactor) { self.redactor = redactor }
    func redact(words: Redacted<String>, app: String) async -> RedactedTypingRun? {
        guard !Self.entirelyPrivate(words.value), !Task.isCancelled else { return nil }
        let safe = await redactor.redact(.init(description: "", text: words.value, details: ["appName": app]))
        guard !Task.isCancelled, safe.report.semanticEngine == .onDeviceModel,
              let text = safe.value.text, !Self.entirelyPrivate(text) else { return nil }
        var report = safe.report
        for (kind, count) in words.report.counts { report.counts[kind, default: 0] += count }
        return .init(app: .init(safe.value.details["appName"] ?? app), words: .init(text, report: report),
                     wordCount: Self.wordCount(text))
    }
    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }
    nonisolated static func entirelyPrivate(_ text: String) -> Bool {
        let without = text.replacingOccurrences(of: "‹[^›]*›", with: "", options: .regularExpression)
        let words = without.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let labels: Set<String> = ["my", "the", "is", "password", "pwd", "secret", "token", "bearer", "pin", "email", "phone", "number", "account", "code"]
        return words.isEmpty || words.allSatisfy { labels.contains(String($0)) }
    }
}
