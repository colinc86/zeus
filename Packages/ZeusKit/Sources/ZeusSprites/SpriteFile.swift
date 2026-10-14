import Foundation

// Raw JSON shapes of a character file (docs/design/SPRITE_FORMAT.md). Decoding only checks
// shape; `SpriteCompiler` does the semantic checks and builds the runtime model.

struct CharacterFile: Decodable {
    var format: Int?
    var id: String
    var name: String
    var summary: String?
    var size: [Int]
    var preferredScale: Int?
    var canvas: CanvasFile
    var emote: EmoteFile?
    var palette: [String: String]
    var palettes: [String: [String: String]]?
    var layers: [String: LayerFile]
    var particles: [String: ParticleFile]?
    var animations: [String: AnimationFile]
}

struct CanvasFile: Decodable {
    var size: [Int]
    var origin: [Int]
    var anchor: [Int]
}

struct EmoteFile: Decodable {
    var at: [Int]
    /// "normal" (default) or "large": the larger glyph set, for characters drawn at a small preferredScale.
    var size: String?
}

struct LayerFile: Decodable {
    var x: Int?
    var y: Int?
    var rows: [String]
}

struct ParticleFile: Decodable {
    var colors: [String]
    var area: [Double]
    var velocity: [Double]?
    var spread: [Double]?
    var gravity: [Double]?
    var life: Double
    var count: Int
    var size: Int?
    var behind: Bool?
    var attached: Bool?
}

struct MotionFile: Decodable {
    var type: String
    var amplitude: Double?
    var period: Double?
}

/// `"name"` or `["a", "b"]`.
struct NameList: Decodable {
    var names: [String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            names = [single]
        } else {
            names = try container.decode([String].self)
        }
    }
}

/// `"layer"` or `{ "layer": "face", "dx": 1, "dy": 0, "flipX": true, "flipY": false, "palette": "glow" }`.
struct LayerRefFile: Decodable {
    var layer: String
    var dx: Int?
    var dy: Int?
    var flipX: Bool?
    var flipY: Bool?
    var palette: NameList?

    private enum CodingKeys: String, CodingKey { case layer, dx, dy, flipX, flipY, palette }

    init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            layer = name
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layer = try c.decode(String.self, forKey: .layer)
        dx = try c.decodeIfPresent(Int.self, forKey: .dx)
        dy = try c.decodeIfPresent(Int.self, forKey: .dy)
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX)
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY)
        palette = try c.decodeIfPresent(NameList.self, forKey: .palette)
    }
}

/// `["body", "face"]` or `{ "layers": [...], "palette": "flash", "hold": 3, "dx": 0, "dy": -1, "flipX": false }`.
struct FrameFile: Decodable {
    var layers: [LayerRefFile]
    var palette: NameList?
    var hold: Int?
    var dx: Int?
    var dy: Int?
    var flipX: Bool?

    private enum CodingKeys: String, CodingKey { case layers, palette, hold, dx, dy, flipX }

    init(from decoder: any Decoder) throws {
        if let refs = try? decoder.singleValueContainer().decode([LayerRefFile].self) {
            layers = refs
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = try c.decodeIfPresent([LayerRefFile].self, forKey: .layers) ?? []
        palette = try c.decodeIfPresent(NameList.self, forKey: .palette)
        hold = try c.decodeIfPresent(Int.self, forKey: .hold)
        dx = try c.decodeIfPresent(Int.self, forKey: .dx)
        dy = try c.decodeIfPresent(Int.self, forKey: .dy)
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX)
    }
}

struct AccentFile: Decodable {
    var layers: [LayerRefFile]?
    var palette: NameList?
    var every: [Double]
    var duration: Double
    var chance: Double?
}

struct AnimationFile: Decodable {
    var fps: Double
    var base: [LayerRefFile]?
    var frames: [FrameFile]
    var over: [LayerRefFile]?
    var palette: NameList?
    var motion: MotionFile?
    var particles: [String]?
    var particleFPS: Double?
    var accents: [AccentFile]?
    var emote: String?
}
