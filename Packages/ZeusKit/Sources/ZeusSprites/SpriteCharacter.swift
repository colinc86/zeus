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
            return (nil, [SpriteIssue(severity: .error, source: source, message: "invalid character JSON: \(Self.describe(error))")])
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

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
