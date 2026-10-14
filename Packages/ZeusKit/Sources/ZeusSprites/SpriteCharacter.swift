import Foundation
import ZeusProtocol

/// A loaded, validated character, ready to render with `SpriteRenderer`.
public struct SpriteCharacter: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    let model: CompiledCharacter
    /// Fingerprint of the character file's bytes. Part of every frame signature, so a user file that
    /// overrides a bundled id (same `id`, different art) never reuses the other's cached frames.
    let contentID: UInt64

    /// Changes whenever the character file's bytes change. Two loads of an unchanged file are equal.
    public var fingerprint: UInt64 { contentID }

    /// The canvas every frame renders into. Constant per character, across all states and frames.
    public var canvasSize: PixelSize { model.canvas }

    /// The character's "feet" point inside the canvas. Constant per character; the app keeps it
    /// fixed on screen.
    public var anchor: PixelPoint { model.anchor }

    /// The points per sprite pixel this character looks best at (JSON `preferredScale`, default 4).
    /// The app multiplies it by the user's size setting.
    public var preferredScale: Int { model.preferredScale }

    /// The states this character draws itself. Other states fall back via `AvatarState.fallback`.
    public var definedStates: [AvatarState] {
        AvatarState.spriteOrder.filter { model.animations[$0] != nil }
    }

    /// The state whose animation is used for `state`, after following the fallback chain.
    public func resolvedState(for state: AvatarState) -> AvatarState {
        var current: AvatarState? = state
        while let s = current {
            if model.animations[s] != nil { return s }
            current = s.fallback
        }
        return .idle
    }

    /// Decodes and validates a character from JSON. Returns `nil` for `character` when there are
    /// errors; warnings don't prevent loading.
    public static func load(data: Data, source: String) -> (character: SpriteCharacter?, issues: [SpriteIssue]) {
        let file: CharacterFile
        do {
            file = try JSONDecoder().decode(CharacterFile.self, from: data)
        } catch {
            return (nil, [SpriteIssue(severity: .error, source: source, message: "invalid character JSON: \(Self.describe(error, data: data))")])
        }
        var compiler = SpriteCompiler(source: source)
        guard let model = compiler.compile(file) else { return (nil, compiler.issues) }
        let character = SpriteCharacter(id: file.id, name: file.name, summary: file.summary ?? "", model: model,
                                        contentID: StableHash.bytes(data))
        return (character, compiler.issues)
    }

    /// Loads and validates the character file at `url`.
    public static func load(contentsOf url: URL) -> (character: SpriteCharacter?, issues: [SpriteIssue]) {
        do {
            return load(data: try Data(contentsOf: url), source: url.lastPathComponent)
        } catch {
            return (nil, [SpriteIssue(severity: .error, source: url.lastPathComponent, message: "can't read file: \(error.localizedDescription)")])
        }
    }

    private static func describe(_ error: any Error, data: Data) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            // A syntax error: Foundation's parser says where ("around line 3, column 1"); pass that on.
            if context.codingPath.isEmpty, let underlying = context.underlyingError as NSError? {
                let detail = (underlying.userInfo[NSDebugDescriptionErrorKey] as? String) ?? context.debugDescription
                if !detail.contains(" line "), let index = underlying.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                    let before = data.prefix(max(0, index))
                    let line = before.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
                    return "syntax error: \(detail.hasSuffix(".") ? String(detail.dropLast()) : detail) around line \(line)."
                }
                if detail.localizedCaseInsensitiveContains("end of file") {
                    // Something isn't closed: a missing } or ], or an unfinished string.
                    let lines = data.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
                    return "syntax error: the file ends too soon (line \(lines)); check for a missing } or ] or an unclosed quote."
                }
                return "syntax error: \(detail)"
            }
            return "\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
