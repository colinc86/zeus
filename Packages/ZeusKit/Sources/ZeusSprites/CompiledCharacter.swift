import ZeusProtocol

// The runtime model a character file compiles into. Everything is resolved to indices, so
// rendering does no string lookups.

/// A straight (non-premultiplied) color with components in 0…1.
struct RGBA: Sendable, Equatable {
    var r: Float
    var g: Float
    var b: Float
    var a: Float

    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// Parses `#rrggbb` or `#rrggbbaa`.
    init?(hex: String) {
        var digits = Substring(hex)
        guard digits.first == "#" else { return nil }
        digits = digits.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? (value << 8) | 0xFF : value
        r = Float((full >> 24) & 0xFF) / 255
        g = Float((full >> 16) & 0xFF) / 255
        b = Float((full >> 8) & 0xFF) / 255
        a = Float(full & 0xFF) / 255
    }

    init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// A palette key index. 0 is transparent; 1… index into `CompiledCharacter.basePalette`.
typealias ColorKey = UInt8

struct CompiledLayer: Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var pixels: [ColorKey]  // row-major, width × height
}

struct LayerRef: Sendable {
    var layer: Int
    var dx = 0
    var dy = 0
    var flipX = false
    var flipY = false
    var palettes: [Int] = []
}

struct Frame: Sendable {
    var refs: [LayerRef]
    var palettes: [Int]
    var hold: Int
    var dx: Int
    var dy: Int
    var flipX: Bool
}

enum MotionKind: String, Sendable {
    case none, float, bob, hop, sway, shake
}

struct Motion: Sendable {
    var kind: MotionKind
    var amplitude: Double
    var period: Double
}

struct ParticleSystem: Sendable {
    var seed: UInt64
    var colors: [ColorKey]
    var area: (x: Double, y: Double, w: Double, h: Double)
    var velocity: (x: Double, y: Double)
    var spread: (x: Double, y: Double)
    var gravity: (x: Double, y: Double)
    var life: Double
    var count: Int
    var size: Int
    var behind: Bool
    var attached: Bool
}

struct Accent: Sendable {
    var seed: UInt64
    var refs: [LayerRef]
    var palettes: [Int]
    var minInterval: Double
    var maxInterval: Double
    var duration: Double
    var chance: Double
}

/// The emote glyphs the renderer draws above every character.
enum EmoteKind: String, Sendable, CaseIterable {
    case thinking, working, alert, waiting, happy, sleeping

    /// The default emote for a state, if any.
    static func `default`(for state: AvatarState) -> EmoteKind? {
        switch state {
        case .thinking: .thinking
        case .working: .working
        case .alert: .alert
        case .waiting: .waiting
        case .happy: .happy
        case .sleeping: .sleeping
        default: nil
        }
    }
}

/// An animation's emote setting: inherit the state's default, force none, or force a glyph.
enum EmoteSetting: Sendable, Equatable {
    case none
    case glyph(EmoteKind)
}

struct Animation: Sendable {
    var fps: Double
    var base: [LayerRef]
    var frames: [Frame]
    var over: [LayerRef]
    var totalTicks: Int
    var palettes: [Int]
    var motion: Motion?
    var particles: [Int]
    /// Particle update rate; `nil` = continuous (sampled at the view's cadence, up to 12 Hz).
    var particleFPS: Double?
    var accents: [Accent]
    var emote: EmoteSetting?
}

struct CompiledCharacter: Sendable {
    var size: PixelSize
    var canvas: PixelSize
    var origin: PixelPoint
    var anchor: PixelPoint
    var preferredScale: Int
    var emoteAt: PixelPoint
    /// Indexed by `ColorKey`; entry 0 is transparent.
    var basePalette: [RGBA]
    /// Named overrides, each a list of (key, color).
    var overrides: [[(ColorKey, RGBA)]]
    var overrideNames: [String]
    var layers: [CompiledLayer]
    var layerNames: [String]
    var particles: [ParticleSystem]
    var animations: [AvatarState: Animation]
    /// Draw the large emote glyphs (`emote.size: "large"`).
    var largeEmotes = false
}
