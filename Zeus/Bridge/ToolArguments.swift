import Foundation
import ZeusProtocol

/// Strict decoding of the snake_case tool boundary, with defaults owned by the runtime.
struct ToolArguments {
    let values: [String: JSONValue]
    init(_ json: JSONValue) throws {
        guard case .object(let values) = json else { throw ToolArgumentError("Arguments must be an object") }
        self.values = values
    }
    func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = values[key] else {
            if required { throw ToolArgumentError("Missing \(key)") }; return nil
        }
        guard case .string(let text) = value else { throw ToolArgumentError("\(key) must be a string") }
        return text
    }
    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key, required: true) else { throw ToolArgumentError("Missing \(key)") }
        return value
    }
    func number(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard case .number(let number) = value, number.isFinite else { throw ToolArgumentError("\(key) must be a finite number") }
        return number
    }
    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard case .bool(let bool) = value else { throw ToolArgumentError("\(key) must be a boolean") }
        return bool
    }
    func progress() throws -> Double? {
        if values["progress"] == .null { return nil }
        let value = try number("progress")
        if let value, !(0...1).contains(value) { throw ToolArgumentError("progress must be between 0 and 1, or null") }
        return value
    }
    func ttl(default fallback: Double? = nil) throws -> Double? {
        let value = try number("ttl_seconds") ?? fallback
        if let value, value < 0 { throw ToolArgumentError("ttl_seconds must be nonnegative") }
        return value
    }
    func enumeration<T: RawRepresentable>(_ key: String, as type: T.Type) throws -> T? where T.RawValue == String {
        guard let value = try string(key) else { return nil }
        guard let result = T(rawValue: value) else { throw ToolArgumentError("Unknown \(key): \(value)") }
        return result
    }
    func array(_ key: String) throws -> [JSONValue] {
        guard let value = values[key] else { return [] }
        guard case .array(let array) = value else { throw ToolArgumentError("\(key) must be an array") }
        return array
    }
    func options(_ key: String) throws -> [CardOption] {
        let result = try array(key).map { json in
            let item = try ToolArguments(json)
            return CardOption(id: try item.requiredString("id"), label: try item.requiredString("label"),
                              style: try item.enumeration("style", as: CardOption.Style.self) ?? .secondary)
        }
        guard Set(result.map(\.id)).count == result.count else { throw ToolArgumentError("\(key) contains duplicate IDs") }
        return result
    }
    static let attachmentSummaryGuidance = "Each file or folder attachment needs a summary: 1–3 sentences saying what's in it and why it matters, so the user doesn't have to open it. Put the takeaway in the message text too."
    func attachments() throws -> [Attachment] {
        try array("attachments").enumerated().map { index, json in
            let item = try ToolArguments(json)
            guard let kind = try item.enumeration("kind", as: Attachment.Kind.self) else { throw ToolArgumentError("Missing attachment kind") }
            let attachment = Attachment(kind: kind, label: try item.requiredString("label"), target: try item.requiredString("target"), summary: try item.string("summary"))
            guard AttachmentTarget.url(for: attachment) != nil else {
                let expected = kind == .url ? "an http(s) URL" : "an absolute or ~ path"
                throw ToolArgumentError("attachments[\(index)].target must be \(expected) for kind \(kind.rawValue)")
            }
            if let summary = attachment.summary, summary.count > 400 {
                throw ToolArgumentError("attachments[\(index)].summary must be at most 400 characters.")
            }
            if kind != .url, (attachment.summary?.filter { !$0.isWhitespace }.count ?? 0) < 20 {
                throw ToolArgumentError(Self.attachmentSummaryGuidance)
            }
            return attachment
        }
    }
}

struct ToolArgumentError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
