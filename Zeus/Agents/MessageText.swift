import Foundation

/// User text normalization shared by composition and text-delivery envelopes.
enum MessageText {
    static func preservingLines(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        while value.last?.isWhitespace == true { value.removeLast() }
        return value
    }
    static func submitted(_ text: String) -> String {
        let value = preservingLines(text)
        // Keep single-line composition's existing trimming behavior.
        return text.utf8.contains(10) ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
