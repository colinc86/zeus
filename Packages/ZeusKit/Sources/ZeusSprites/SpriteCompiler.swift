import Foundation
import ZeusProtocol

/// A problem found while validating a character file.
public struct SpriteIssue: Sendable, Hashable, CustomStringConvertible {
    /// How serious the issue is. Errors stop the character from loading; warnings don't.
    public enum Severity: String, Sendable, Hashable {
        case error, warning
    }

    public var severity: Severity
    /// The file (or character id) the issue was found in.
    public var source: String
    public var message: String

    public init(severity: Severity, source: String, message: String) {
        self.severity = severity
        self.source = source
        self.message = message
    }

    public var description: String { "\(source): \(severity.rawValue): \(message)" }
}

/// Turns a `CharacterFile` into a `CompiledCharacter`, collecting every issue it finds.
struct SpriteCompiler {
    static let supportedFormat = 1
    static let transparentKeys: Set<Character> = [".", " "]

    let source: String
    private(set) var issues: [SpriteIssue] = []

    init(source: String) {
        self.source = source
    }

    var hasErrors: Bool { issues.contains { $0.severity == .error } }

    mutating func error(_ message: String) {
        issues.append(SpriteIssue(severity: .error, source: source, message: message))
    }

    mutating func warning(_ message: String) {
        issues.append(SpriteIssue(severity: .warning, source: source, message: message))
    }

    // MARK: - Compile

    mutating func compile(_ file: CharacterFile) -> CompiledCharacter? {
        if let format = file.format, format > Self.supportedFormat {
            error("format \(format) is newer than this renderer supports (\(Self.supportedFormat))")
        }
        if file.id.isEmpty || file.id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            error("id \"\(file.id)\" must be non-empty and use only letters, digits, - and _")
        }

        let size = pair(file.size, "size", min: 1).map { PixelSize(width: $0.0, height: $0.1) }
        let canvas = pair(file.canvas.size, "canvas.size", min: 1).map { PixelSize(width: $0.0, height: $0.1) }
        let origin = pair(file.canvas.origin, "canvas.origin", min: 0).map { PixelPoint(x: $0.0, y: $0.1) }
        let anchor = pair(file.canvas.anchor, "canvas.anchor", min: 0).map { PixelPoint(x: $0.0, y: $0.1) }
        let emoteAt = file.emote.flatMap { pair($0.at, "emote.at", min: nil) }.map { PixelPoint(x: $0.0, y: $0.1) }
        var largeEmotes = false
        switch file.emote?.size {
        case nil, "normal": break
        case "large": largeEmotes = true
        case let other?: error("emote.size \"\(other)\" must be \"normal\" or \"large\"")
        }

        let preferredScale = file.preferredScale ?? 4
        if !(1...16).contains(preferredScale) {
            error("preferredScale must be 1…16 (points per pixel)")
        }
        guard let size, let canvas, let origin, let anchor else { return nil }
        if origin.x + size.width > canvas.width || origin.y + size.height > canvas.height {
            error("canvas.origin + size (\(origin.x + size.width)×\(origin.y + size.height)) exceeds canvas.size (\(canvas.width)×\(canvas.height))")
        }
        if anchor.x >= canvas.width || anchor.y > canvas.height {
            error("canvas.anchor (\(anchor.x),\(anchor.y)) is outside the canvas")
        }

        // Palette
        var keyIndex: [Character: ColorKey] = [:]
        var basePalette: [RGBA] = [.clear]
        for (key, hex) in file.palette.sorted(by: { $0.key < $1.key }) {
            guard key.count == 1, let char = key.first else {
                error("palette key \"\(key)\" must be a single character")
                continue
            }
            if Self.transparentKeys.contains(char) {
                error("palette key \"\(key)\" is reserved for transparency")
                continue
            }
            guard let color = RGBA(hex: hex) else {
                error("palette \"\(key)\": \"\(hex)\" is not #rrggbb or #rrggbbaa")
                continue
            }
            guard basePalette.count < Int(ColorKey.max) else {
                error("palette has too many colors (max \(ColorKey.max - 1))")
                break
            }
            keyIndex[char] = ColorKey(basePalette.count)
            basePalette.append(color)
        }

        // Named palette overrides
        let overrideNames = (file.palettes ?? [:]).keys.sorted()
        var overrides: [[(ColorKey, RGBA)]] = []
        for name in overrideNames {
            var entries: [(ColorKey, RGBA)] = []
            for (key, hex) in (file.palettes?[name] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard key.count == 1, let char = key.first, let index = keyIndex[char] else {
                    error("palettes.\(name): key \"\(key)\" isn't in the base palette")
                    continue
                }
                guard let color = RGBA(hex: hex) else {
                    error("palettes.\(name).\(key): \"\(hex)\" is not #rrggbb or #rrggbbaa")
                    continue
                }
                entries.append((index, color))
            }
            overrides.append(entries)
        }
        let overrideIndex = Dictionary(uniqueKeysWithValues: overrideNames.enumerated().map { ($1, $0) })

        // Layers
        let layerNames = file.layers.keys.sorted()
        var layers: [CompiledLayer] = []
        for name in layerNames {
            guard let spec = file.layers[name] else { continue }
            layers.append(compileLayer(name, spec, keyIndex: keyIndex))
        }
        let layerIndex = Dictionary(uniqueKeysWithValues: layerNames.enumerated().map { ($1, $0) })

        // Particles
        let particleNames = (file.particles ?? [:]).keys.sorted()
        var particles: [ParticleSystem] = []
        for name in particleNames {
            guard let spec = file.particles?[name] else { continue }
            particles.append(compileParticles(name, spec, keyIndex: keyIndex))
        }
        let particleIndex = Dictionary(uniqueKeysWithValues: particleNames.enumerated().map { ($1, $0) })

        // Animations
        var animations: [AvatarState: Animation] = [:]
        var resolver = RefResolver(layerIndex: layerIndex, overrideIndex: overrideIndex)
        for (key, spec) in file.animations.sorted(by: { $0.key < $1.key }) {
            guard let state = AvatarState(spriteKey: key) else {
                error("animations.\(key): not an avatar state (\(AvatarState.spriteOrder.map(\.spriteKey).joined(separator: ", ")))")
                continue
            }
            animations[state] = compileAnimation(key, spec, resolver: &resolver, particleIndex: particleIndex)
        }
        issues.append(contentsOf: resolver.issues.map { SpriteIssue(severity: .error, source: source, message: $0) })
        if animations[.idle] == nil {
            error("animations.idle is required")
        }

        let character = CompiledCharacter(
            size: size, canvas: canvas, origin: origin, anchor: anchor, preferredScale: preferredScale,
            emoteAt: emoteAt ?? PixelPoint(x: size.width / 2, y: -1),
            basePalette: basePalette, overrides: overrides, overrideNames: overrideNames,
            layers: layers, layerNames: layerNames, particles: particles, animations: animations,
            largeEmotes: largeEmotes
        )
        if !hasErrors {
            checkBounds(character)
        }
        return hasErrors ? nil : character
    }

    // MARK: - Pieces

    private mutating func pair(_ values: [Int], _ field: String, min: Int?) -> (Int, Int)? {
        guard values.count == 2 else {
            error("\(field) must be [x, y] / [width, height]")
            return nil
        }
        if let min, values[0] < min || values[1] < min {
            error("\(field) values must be ≥ \(min)")
            return nil
        }
        return (values[0], values[1])
    }

    private mutating func compileLayer(_ name: String, _ spec: LayerFile, keyIndex: [Character: ColorKey]) -> CompiledLayer {
        let rows = spec.rows.map(Array.init)
        let width = rows.map(\.count).max() ?? 0
        if rows.isEmpty || width == 0 {
            warning("layers.\(name) is empty")
        }
        if rows.contains(where: { $0.count != width }) {
            error("layers.\(name): rows have different lengths")
        }
        var pixels = [ColorKey](repeating: 0, count: width * rows.count)
        var unknown: Set<Character> = []
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() where !Self.transparentKeys.contains(char) {
                if let key = keyIndex[char] {
                    pixels[y * width + x] = key
                } else {
                    unknown.insert(char)
                }
            }
        }
        if !unknown.isEmpty {
            error("layers.\(name): unknown palette keys \(unknown.sorted().map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        return CompiledLayer(x: spec.x ?? 0, y: spec.y ?? 0, width: width, height: rows.count, pixels: pixels)
    }

    private mutating func compileParticles(_ name: String, _ spec: ParticleFile, keyIndex: [Character: ColorKey]) -> ParticleSystem {
        var colors: [ColorKey] = []
        for key in spec.colors {
            if key.count == 1, let char = key.first, let index = keyIndex[char] {
                colors.append(index)
            } else {
                error("particles.\(name): color \"\(key)\" isn't a palette key")
            }
        }
        if colors.isEmpty { error("particles.\(name): needs at least one color") }
        if spec.area.count != 4 { error("particles.\(name).area must be [x, y, width, height]") }
        if spec.life <= 0 { error("particles.\(name).life must be > 0") }
        if spec.count < 0 || spec.count > 64 { error("particles.\(name).count must be 0…64") }
        func xy(_ v: [Double]?, _ field: String) -> (x: Double, y: Double) {
            guard let v else { return (0, 0) }
            guard v.count == 2 else {
                error("particles.\(name).\(field) must be [x, y]")
                return (0, 0)
            }
            return (v[0], v[1])
        }
        let area = spec.area.count == 4 ? (x: spec.area[0], y: spec.area[1], w: spec.area[2], h: spec.area[3]) : (x: 0.0, y: 0.0, w: 0.0, h: 0.0)
        return ParticleSystem(
            seed: StableHash.string(name), colors: colors, area: area,
            velocity: xy(spec.velocity, "velocity"), spread: xy(spec.spread, "spread"), gravity: xy(spec.gravity, "gravity"),
            life: max(spec.life, 0.01), count: max(0, min(spec.count, 64)), size: max(1, spec.size ?? 1),
            behind: spec.behind ?? false, attached: spec.attached ?? true
        )
    }

    private mutating func compileAnimation(_ key: String, _ spec: AnimationFile, resolver: inout RefResolver, particleIndex: [String: Int]) -> Animation {
        let path = "animations.\(key)"
        if spec.fps <= 0 || spec.fps > 60 { error("\(path).fps must be in (0, 60]") }
        if spec.frames.isEmpty { error("\(path).frames must not be empty") }

        let base = (spec.base ?? []).map { resolver.ref($0, at: "\(path).base") }
        let over = (spec.over ?? []).map { resolver.ref($0, at: "\(path).over") }
        var frames: [Frame] = []
        for (i, f) in spec.frames.enumerated() {
            let fpath = "\(path).frames[\(i)]"
            let hold = f.hold ?? 1
            if hold < 1 { error("\(fpath).hold must be ≥ 1") }
            frames.append(Frame(
                refs: f.layers.map { resolver.ref($0, at: fpath) },
                palettes: resolver.palettes(f.palette, at: fpath),
                hold: max(hold, 1), dx: f.dx ?? 0, dy: f.dy ?? 0, flipX: f.flipX ?? false
            ))
        }

        var motion: Motion?
        if let m = spec.motion {
            if let kind = MotionKind(rawValue: m.type) {
                let period = m.period ?? 2
                if period <= 0 { error("\(path).motion.period must be > 0") }
                motion = Motion(kind: kind, amplitude: m.amplitude ?? 1, period: max(period, 0.01))
            } else {
                error("\(path).motion.type \"\(m.type)\" must be one of none, float, bob, hop, sway, shake")
            }
        }

        var particles: [Int] = []
        for name in spec.particles ?? [] {
            if let index = particleIndex[name] {
                particles.append(index)
            } else {
                error("\(path).particles: unknown particle system \"\(name)\"")
            }
        }

        if let rate = spec.particleFPS, !(rate > 0 && rate <= 60) {
            error("\(path).particleFPS must be in (0, 60]")
        }

        var accents: [Accent] = []
        for (i, a) in (spec.accents ?? []).enumerated() {
            let apath = "\(path).accents[\(i)]"
            guard a.every.count == 2, a.every[0] > 0, a.every[0] <= a.every[1] else {
                error("\(apath).every must be [min, max] seconds with 0 < min ≤ max")
                continue
            }
            if a.duration <= 0 || a.duration > a.every[0] { error("\(apath).duration must be > 0 and ≤ every[0]") }
            accents.append(Accent(
                seed: StableHash.string("\(key)#\(i)"),
                refs: (a.layers ?? []).map { resolver.ref($0, at: apath) },
                palettes: resolver.palettes(a.palette, at: apath),
                minInterval: a.every[0], maxInterval: a.every[1], duration: a.duration,
                chance: min(max(a.chance ?? 1, 0), 1)
            ))
        }

        var emote: EmoteSetting?
        if let e = spec.emote {
            if e == "none" {
                emote = EmoteSetting.none
            } else if let kind = EmoteKind(rawValue: e) {
                emote = .glyph(kind)
            } else {
                error("\(path).emote \"\(e)\" must be \"none\" or one of \(EmoteKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
        }

        return Animation(
            fps: max(spec.fps, 0.01), base: base, frames: frames, over: over,
            totalTicks: max(frames.reduce(0) { $0 + $1.hold }, 1),
            palettes: resolver.palettes(spec.palette, at: path),
            motion: motion, particles: particles,
            particleFPS: spec.particleFPS.flatMap { $0 > 0 && $0 <= 60 ? $0 : nil },
            accents: accents, emote: emote
        )
    }

    /// Warns when an animation can draw art (or an emote) outside the canvas, where it would be clipped.
    private mutating func checkBounds(_ c: CompiledCharacter) {
        for state in AvatarState.spriteOrder {
            guard let anim = c.animations[state] else { continue }
            let motion = anim.motion.map { m -> (Int, Int) in
                let a = Int(m.amplitude.rounded(.up))
                switch m.kind {
                case .none: return (0, 0)
                case .float, .bob, .hop: return (0, a)
                case .sway, .shake: return (a, 0)
                }
            } ?? (0, 0)
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            for frame in anim.frames {
                for ref in anim.base + frame.refs + anim.over {
                    let l = c.layers[ref.layer]
                    guard l.width > 0, l.height > 0 else { continue }
                    var x0 = l.x + ref.dx
                    let x1 = x0 + l.width - 1
                    if frame.flipX { x0 = c.size.width - 1 - x1 }
                    let y0 = l.y + ref.dy
                    minX = min(minX, x0 + frame.dx - motion.0)
                    maxX = max(maxX, x0 + l.width - 1 + frame.dx + motion.0)
                    minY = min(minY, y0 + frame.dy - motion.1)
                    maxY = max(maxY, y0 + l.height - 1 + frame.dy + motion.1)
                }
            }
            guard minX != Int.max else { continue }
            if c.origin.x + minX < 0 || c.origin.y + minY < 0
                || c.origin.x + maxX >= c.canvas.width || c.origin.y + maxY >= c.canvas.height {
                warning("animations.\(state.spriteKey) can draw outside the canvas (art spans x \(minX)…\(maxX), y \(minY)…\(maxY) in sprite space); it will be clipped")
            }
        }
        // Emote glyphs sit centered on emote.at, extending upward.
        let glyphs = Emotes.glyphs(large: c.largeEmotes)
        let top = c.origin.y + c.emoteAt.y - glyphs.maxHeight
        let left = c.origin.x + c.emoteAt.x - glyphs.maxWidth / 2
        if top < 0 || left < 0 || left + glyphs.maxWidth > c.canvas.width {
            warning("emote.at leaves too little room for emotes (need \(glyphs.maxWidth)×\(glyphs.maxHeight) px above it inside the canvas)")
        }
    }
}

/// Resolves layer and palette names to indices, remembering unknown names.
struct RefResolver {
    let layerIndex: [String: Int]
    let overrideIndex: [String: Int]
    private(set) var issues: [String] = []

    init(layerIndex: [String: Int], overrideIndex: [String: Int]) {
        self.layerIndex = layerIndex
        self.overrideIndex = overrideIndex
    }

    mutating func ref(_ file: LayerRefFile, at path: String) -> LayerRef {
        let index = layerIndex[file.layer]
        if index == nil { issues.append("\(path): unknown layer \"\(file.layer)\"") }
        return LayerRef(
            layer: index ?? 0, dx: file.dx ?? 0, dy: file.dy ?? 0,
            flipX: file.flipX ?? false, flipY: file.flipY ?? false,
            palettes: palettes(file.palette, at: path)
        )
    }

    mutating func palettes(_ list: NameList?, at path: String) -> [Int] {
        (list?.names ?? []).compactMap { name in
            if let index = overrideIndex[name] { return index }
            issues.append("\(path): unknown palette \"\(name)\"")
            return nil
        }
    }
}
