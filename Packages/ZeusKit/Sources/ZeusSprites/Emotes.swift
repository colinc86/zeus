import Foundation

/// The renderer's built-in emote glyphs. Each glyph is a fill mask that gets a 1-px dark
/// outline, so it reads on any desktop background. Emotes are positioned by their
/// bottom-center point (the character's `emote.at`), and animate as a pure function of time.
enum Emotes {
    static let outline = RGBA(r: 0.11, g: 0.10, b: 0.18, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let gold = RGBA(r: 1.0, g: 0.83, b: 0.25, a: 1)
    static let sky = RGBA(r: 0.55, g: 0.84, b: 1.0, a: 1)
    static let rose = RGBA(r: 1.0, g: 0.36, b: 0.48, a: 1)
    static let steel = RGBA(r: 0.80, g: 0.83, b: 0.90, a: 1)
    static let dream = RGBA(r: 0.78, g: 0.86, b: 1.0, a: 1)

    struct Glyph {
        let width: Int
        let height: Int
        let mask: [Bool]

        init(_ rows: [String]) {
            width = rows.map(\.count).max() ?? 0
            height = rows.count
            var mask = [Bool](repeating: false, count: width * height)
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    mask[y * width + x] = true
                }
            }
            self.mask = mask
        }

        func filled(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x]
        }
    }

    /// One size of the glyph set. `large` is for characters drawn at a small `preferredScale` (Zeus, at 3),
    /// so their emotes come out about as big on screen as everyone else's (Q2 DES-19).
    struct GlyphSet: Sendable {
        let dot: Glyph
        let dotSpacing: Int
        let bang: Glyph
        let question: Glyph
        let heartBig: Glyph
        let heartSmall: Glyph
        let zBig: Glyph
        let zSmall: Glyph
        let gear: Glyph
        /// The gear's teeth in clockwise order; a highlighted tooth travels around to show it turning.
        let gearTeeth: [(Int, Int)]
        /// The largest outlined footprint, including motion, used to validate `emote.at` placement.
        let maxWidth: Int
        let maxHeight: Int
    }

    static let normal = GlyphSet(
        dot: Glyph(["##", "##"]), dotSpacing: 3,
        bang: Glyph(["##", "##", "##", "##", "..", "##"]),
        question: Glyph([".###.", "##.##", "...##", "..##.", ".....", "..##."]),
        heartBig: Glyph([".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]),
        heartSmall: Glyph([".#.#.", "#####", ".###.", "..#.."]),
        zBig: Glyph(["####", "..#.", ".#..", "####"]),
        zSmall: Glyph(["###", ".#.", "###"]),
        gear: Glyph(["..#.#..", ".#####.", "###.###", ".#...#.", "###.###", ".#####.", "..#.#.."]),
        gearTeeth: [(2, 0), (4, 0), (6, 2), (6, 4), (4, 6), (2, 6), (0, 4), (0, 2)],
        maxWidth: 11, maxHeight: 12)

    static let large = GlyphSet(
        dot: Glyph(["###", "###", "###"]), dotSpacing: 4,
        bang: Glyph(["###", "###", "###", "###", "###", "...", "###", "###"]),
        question: Glyph([".#####.", "##...##", ".....##", "....##.", "...##..", "...##..", ".......", "...##.."]),
        heartBig: Glyph([".###.###.", "#########", "#########", "#########", ".#######.", "..#####..", "...###...", "....#...."]),
        heartSmall: Glyph([".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]),
        zBig: Glyph(["######", "....##", "...##.", "..##..", ".##...", "######"]),
        zSmall: Glyph(["####", "..#.", ".#..", "####"]),
        gear: Glyph(["...###...", ".#.###.#.", ".#######.", "####.####", "###...###", "####.####", ".#######.", ".#.###.#.", "...###..."]),
        gearTeeth: [(4, 0), (7, 1), (8, 4), (7, 7), (4, 8), (1, 7), (0, 4), (1, 1)],
        maxWidth: 13, maxHeight: 13)

    static func glyphs(large: Bool) -> GlyphSet { large ? Self.large : normal }

    /// Draws `glyph` with its outline so that the outlined box's bottom-center is at (cx, bottom).
    static func draw(_ glyph: Glyph, color: RGBA, centerX cx: Int, bottom: Int, opacity: Float = 1, into buffer: inout PixelBuffer) {
        let left = cx - (glyph.width + 2) / 2 + 1
        let top = bottom - glyph.height
        for gy in -1...glyph.height {
            for gx in -1...glyph.width {
                if glyph.filled(gx, gy) {
                    buffer.blend(left + gx, top + gy, color, opacity: opacity)
                } else if (-1...1).contains(where: { dy in (-1...1).contains { dx in glyph.filled(gx + dx, gy + dy) } }) {
                    buffer.blend(left + gx, top + gy, outline, opacity: opacity)
                }
            }
        }
    }

    /// Draws the emote for `kind` at `time`, bottom-centered on (cx, bottom).
    static func draw(_ kind: EmoteKind, time t: Double, glyphs: GlyphSet = normal, centerX cx: Int, bottom: Int, reduceMotion: Bool, into buffer: inout PixelBuffer) {
        draw(plan(kind, time: t, reduceMotion: reduceMotion), glyphs: glyphs, centerX: cx, bottom: bottom, into: &buffer)
    }

    /// The emote's discrete appearance at `time`. Everything `draw(_:centerX:bottom:into:)` uses comes
    /// from here, so equal plans draw identical pixels (it's part of `SpriteFrameSignature`).
    static func plan(_ kind: EmoteKind, time t: Double, reduceMotion: Bool) -> EmotePlan {
        switch kind {
        case .thinking:
            // Dots appear one by one, then hold: · ·· ··· ···
            return .thinking(dots: reduceMotion ? 3 : min(Int(floorMod(t * 3, 4)) + 1, 3))
        case .alert:
            return .alert(dy: !reduceMotion && floorMod(t, 0.6) < 0.15 ? -1 : 0)
        case .waiting:
            return .waiting(dx: reduceMotion ? 0 : (floorMod(t, 1.6) < 0.8 ? 0 : 1))
        case .happy:
            // Heartbeat: two quick beats, then rest.
            let p = floorMod(t, 1.0)
            return .happy(beat: !reduceMotion && (p < 0.12 || (p >= 0.24 && p < 0.36)))
        case .working:
            return .working(tooth: reduceMotion ? 0 : Int(floorMod(t * 8, Double(normal.gearTeeth.count))))
        case .sleeping:
            if reduceMotion { return .sleeping([.init(big: true, dx: 2, dy: 0, fade: fadeSteps)]) }
            // Two z's drifting up and to the right, fading out at the top.
            var zs: [EmotePlan.Z] = []
            for j in 0..<2 {
                let u = floorMod(t / 2.4 + Double(j) / 2, 1)
                let dx = Int((u * 4).rounded()) + (u > 0.5 ? 1 : 0)
                let dy = 2 - Int((u * 6).rounded())
                let fade = u > 0.75 ? 1 - (u - 0.75) / 0.25 : 1
                zs.append(.init(big: u >= 0.4, dx: dx, dy: dy, fade: Int((fade * Double(fadeSteps)).rounded())))
            }
            return .sleeping(zs)
        }
    }

    /// Opacity steps for fading z's: quantized so the plan (and so the signature) captures it exactly.
    static let fadeSteps = 16

    static func draw(_ plan: EmotePlan, glyphs g: GlyphSet = normal, centerX cx: Int, bottom: Int, into buffer: inout PixelBuffer) {
        switch plan {
        case .thinking(let dots):
            for i in 0..<dots {
                draw(g.dot, color: white, centerX: cx - g.dotSpacing + i * g.dotSpacing, bottom: bottom, into: &buffer)
            }
        case .alert(let dy):
            draw(g.bang, color: gold, centerX: cx, bottom: bottom + dy, into: &buffer)
        case .waiting(let dx):
            draw(g.question, color: sky, centerX: cx + dx, bottom: bottom, into: &buffer)
        case .happy(let beat):
            draw(beat ? g.heartBig : g.heartSmall, color: rose, centerX: cx, bottom: bottom - (beat ? 0 : 1), into: &buffer)
        case .working(let step):
            draw(g.gear, color: steel, centerX: cx, bottom: bottom, into: &buffer)
            let tooth = g.gearTeeth[step % g.gearTeeth.count]
            let left = cx - (g.gear.width + 2) / 2 + 1
            buffer.blend(left + tooth.0, bottom - g.gear.height + tooth.1, gold)
        case .sleeping(let zs):
            for z in zs {
                draw(z.big ? g.zBig : g.zSmall, color: dream, centerX: cx + z.dx, bottom: bottom + z.dy,
                     opacity: Float(z.fade) / Float(fadeSteps), into: &buffer)
            }
        }
    }
}

/// An emote's discrete appearance (see `Emotes.plan`).
enum EmotePlan: Hashable, Sendable {
    struct Z: Hashable, Sendable {
        var big: Bool
        var dx: Int
        var dy: Int
        var fade: Int
    }
    case thinking(dots: Int)
    case alert(dy: Int)
    case waiting(dx: Int)
    case happy(beat: Bool)
    case working(tooth: Int)
    case sleeping([Z])
}

/// `a mod m` that is non-negative for negative `a`.
func floorMod(_ a: Double, _ m: Double) -> Double {
    a - (a / m).rounded(.down) * m
}
