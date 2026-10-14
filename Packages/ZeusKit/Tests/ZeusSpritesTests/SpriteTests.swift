import CoreGraphics
import ZeusProtocol
import Foundation
import Testing
@testable import ZeusSprites

// MARK: - Helpers

/// A small character for format tests; `extra` is spliced into the top-level object.
func makeCharacter(animations: String, extra: String = "", source: String = "test.json") -> (character: SpriteCharacter?, issues: [SpriteIssue]) {
    let json = """
    {
      "format": 1, "id": "tester", "name": "Tester", "summary": "test",
      "size": [4, 4],
      "canvas": { "size": [24, 24], "origin": [10, 14], "anchor": [12, 18] },
      "emote": { "at": [2, -1] },
      "palette": { "k": "#000000", "r": "#ff0000", "g": "#00ff00", "h": "#ff000080" },
      "palettes": { "swap": { "r": "#0000ff" } },
      "layers": {
        "body": { "rows": ["kkkk", "krrk", "krrk", "kkkk"] },
        "dot": { "x": 1, "y": 1, "rows": ["g"] },
        "left": { "rows": ["r..."] }
      },
      "particles": { "spark": { "colors": ["g", "r"], "area": [0, 0, 4, 2], "velocity": [0, -3], "spread": [2, 1], "life": 0.5, "count": 3 } }
      \(extra),
      "animations": { \(animations) }
    }
    """
    return SpriteCharacter.load(data: Data(json.utf8), source: source)
}

func pixels(_ image: CGImage) -> [UInt8] {
    let data = image.dataProvider?.data as Data?
    return data.map(Array.init) ?? []
}

func rgba(_ buffer: PixelBuffer, _ x: Int, _ y: Int) -> SIMD4<Float> {
    buffer.pixels[y * buffer.width + x]
}

let sampleTimes: [TimeInterval] = [0, 0.13, 0.5, 1.07, 2.4, 3.33, 7.9, 61.25, -1.5]

// MARK: - Bundled characters

@Test func bundledCharactersValidateCleanly() throws {
    let directory = try #require(CharacterLibrary.bundledDirectory)
    let (characters, issues) = CharacterLibrary.loadDirectory(directory)
    #expect(issues.isEmpty, "\(issues)")
    #expect(!characters.isEmpty)
    let library = CharacterLibrary.load(userDirectory: nil)
    #expect(library.issues.isEmpty)
    #expect(library.characters.first?.id == CharacterLibrary.defaultCharacterID)
    #expect(library.characters.map(\.id) == CharacterLibrary.bundledOrder)
}

@Test func bundledRosterIsComplete() {
    let library = CharacterLibrary.load(userDirectory: nil)
    #expect(Set(library.characters.map(\.id)).isSuperset(of: ["zeus", "ghost", "pumpkin", "robot", "hero", "wizard", "cat", "skeleton", "slime", "bat", "owl", "mushroom"]))
    #expect(library.characters.count == 12)
    for character in library.characters {
        #expect(character.definedStates == AvatarState.spriteOrder, "\(character.id) should draw every state")
        #expect((2...8).contains(character.preferredScale), "\(character.id)")
    }
    #expect(library.character(id: "zeus")?.preferredScale == 3)
}

@Test(arguments: AvatarState.spriteOrder)
func bundledRenderingIsDeterministic(state: AvatarState) {
    for character in CharacterLibrary.load(userDirectory: nil).characters {
        for t in sampleTimes {
            let a = SpriteRenderer.render(character, state: state, time: t)
            let b = SpriteRenderer.render(character, state: state, time: t)
            #expect(pixels(a) == pixels(b), "\(character.id) \(state) t=\(t)")
        }
    }
}

@Test func canvasAndAnchorAreConstantAcrossStatesAndTimes() {
    for character in CharacterLibrary.load(userDirectory: nil).characters {
        let size = character.canvasSize
        #expect(character.anchor.x >= 0 && character.anchor.x < size.width)
        #expect(character.anchor.y >= 0 && character.anchor.y <= size.height)
        for state in AvatarState.spriteOrder {
            for t in sampleTimes {
                for options in [RenderOptions(), RenderOptions(showEmote: false, reduceMotion: true)] {
                    let image = SpriteRenderer.render(character, state: state, time: t, options: options)
                    #expect(image.width == size.width && image.height == size.height, "\(character.id) \(state) t=\(t)")
                }
            }
        }
    }
}

@Test func bundledStatesLookDistinct() {
    let options = RenderOptions(showEmote: false)
    for character in CharacterLibrary.load(userDirectory: nil).characters {
        let images = AvatarState.spriteOrder.map { pixels(SpriteRenderer.render(character, state: $0, time: 0.3, options: options)) }
        let duplicates = AvatarState.spriteOrder.indices.flatMap { a in
            AvatarState.spriteOrder.indices.filter { $0 > a && images[$0] == images[a] }.map { "\(AvatarState.spriteOrder[a])=\(AvatarState.spriteOrder[$0])" }
        }
        #expect(duplicates.isEmpty, "\(character.id): every state should differ even without its emote: \(duplicates)")
    }
}

@Test func bundledCharactersAnimateInEveryState() {
    for character in CharacterLibrary.load(userDirectory: nil).characters {
        for state in AvatarState.spriteOrder {
            let frames = Set(stride(from: 0.0, to: 6.0, by: 0.1).map { pixels(SpriteRenderer.render(character, state: state, time: $0)) })
            #expect(frames.count > 3, "\(character.id) \(state) should change over time")
        }
    }
}

// MARK: - Format & validation

@Test func minimalCharacterLoads() throws {
    let (character, issues) = makeCharacter(animations: #""idle": { "fps": 1, "frames": [["body"]] }"#)
    #expect(issues.isEmpty, "\(issues)")
    let c = try #require(character)
    #expect(c.canvasSize == PixelSize(width: 24, height: 24))
    #expect(c.anchor == PixelPoint(x: 12, y: 18))
    #expect(c.definedStates == [.idle])
    #expect(c.preferredScale == 4)
}

@Test func preferredScaleIsValidated() {
    let (bad, issues) = makeCharacter(animations: #""idle": { "fps": 1, "frames": [["body"]] }"#, extra: #", "preferredScale": 0"#)
    #expect(bad == nil)
    #expect(issues.contains { $0.message.contains("preferredScale") })
    let (good, _) = makeCharacter(animations: #""idle": { "fps": 1, "frames": [["body"]] }"#, extra: #", "preferredScale": 6"#)
    #expect(good?.preferredScale == 6)
}

@Test func fallbackFollowsTheStateChain() throws {
    let (character, _) = makeCharacter(animations: #"""
        "idle": { "fps": 1, "frames": [["body"]] },
        "thinking": { "fps": 1, "frames": [["body", "dot"]] },
        "alert": { "fps": 1, "frames": [["dot"]] }
        """#)
    let c = try #require(character)
    #expect(c.resolvedState(for: .working) == .thinking)
    #expect(c.resolvedState(for: .waiting) == .alert)
    #expect(c.resolvedState(for: .happy) == .idle)
    #expect(c.resolvedState(for: .sleeping) == .idle)
    #expect(c.resolvedState(for: .thinking) == .thinking)
}

@Test func validationReportsProblems() {
    let cases: [(String, String, String)] = [
        (#""thinking": { "fps": 1, "frames": [["body"]] }"#, "", "animations.idle is required"),
        (#""idle": { "fps": 1, "frames": [["nope"]] }"#, "", "unknown layer \"nope\""),
        (#""idle": { "fps": 1, "frames": [{ "layers": ["body"], "palette": "nope" }] }"#, "", "unknown palette \"nope\""),
        (#""idle": { "fps": 0, "frames": [["body"]] }"#, "", "fps"),
        (#""idle": { "fps": 1, "frames": [] }"#, "", "frames must not be empty"),
        (#""dancing": { "fps": 1, "frames": [["body"]] }, "idle": { "fps": 1, "frames": [["body"]] }"#, "", "not an avatar state"),
        (#""idle": { "fps": 1, "frames": [["body"]], "particles": ["nope"] }"#, "", "unknown particle system"),
        (#""idle": { "fps": 1, "frames": [["body"]], "motion": { "type": "spin" } }"#, "", "motion.type"),
        (#""idle": { "fps": 1, "frames": [["body"]], "emote": "dance" }"#, "", "emote"),
        (#""idle": { "fps": 1, "frames": [["body"]], "accents": [{ "every": [3, 1], "duration": 0.1 }] }"#, "", "every"),
    ]
    for (animations, extra, expected) in cases {
        let (character, issues) = makeCharacter(animations: animations, extra: extra)
        #expect(character == nil, "\(expected)")
        #expect(issues.contains { $0.severity == .error && $0.message.contains(expected) }, "expected \(expected) in \(issues)")
    }
}

@Test func validationCatchesBadArt() {
    func load(_ layer: String, palette: String = ##""k": "#000000""##) -> [SpriteIssue] {
        let json = """
        { "id": "bad", "name": "Bad", "size": [4, 4],
          "canvas": { "size": [8, 8], "origin": [0, 0], "anchor": [4, 8] },
          "palette": { \(palette) },
          "layers": { "a": \(layer) },
          "animations": { "idle": { "fps": 1, "frames": [["a"]] } } }
        """
        return SpriteCharacter.load(data: Data(json.utf8), source: "bad.json").issues
    }
    #expect(load(#"{ "rows": ["kk", "k"] }"#).contains { $0.message.contains("different lengths") })
    #expect(load(#"{ "rows": ["kz"] }"#).contains { $0.message.contains("unknown palette keys \"z\"") })
    #expect(load(#"{ "rows": ["k"] }"#, palette: ##""k": "red""##).contains { $0.message.contains("not #rrggbb") })
    #expect(load(#"{ "rows": ["k"] }"#, palette: ##"".": "#000000""##).contains { $0.message.contains("reserved") })
    #expect(load(#"{ "rows": ["kkkkkkkkkk"] }"#).contains { $0.severity == .warning && $0.message.contains("outside the canvas") })
    #expect(SpriteCharacter.load(data: Data("{".utf8), source: "x.json").issues.first?.message.contains("invalid character JSON") == true)
}

@Test func canvasMustContainTheSprite() {
    let json = """
    { "id": "big", "name": "Big", "size": [10, 10],
      "canvas": { "size": [8, 8], "origin": [0, 0], "anchor": [4, 8] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": ["k"] } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]] } } }
    """
    let (character, issues) = SpriteCharacter.load(data: Data(json.utf8), source: "big.json")
    #expect(character == nil)
    #expect(issues.contains { $0.message.contains("exceeds canvas.size") })
}

@Test func hexColorsParseWithAndWithoutAlpha() throws {
    let opaque = try #require(RGBA(hex: "#ff8000"))
    #expect(opaque == RGBA(r: 1, g: Float(0x80) / 255, b: 0, a: 1))
    let translucent = try #require(RGBA(hex: "#00000080"))
    #expect(abs(translucent.a - Float(0x80) / 255) < 0.0001)
    #expect(RGBA(hex: "ff0000") == nil)
    #expect(RGBA(hex: "#ff00") == nil)
    #expect(RGBA(hex: "#gg0000") == nil)
}

// MARK: - Rendering

@Test func layersFramesFlipsAndPalettes() throws {
    let (character, _) = makeCharacter(animations: #"""
        "idle": { "fps": 1, "frames": [
            ["body", "dot"],
            { "layers": ["body"], "palette": "swap" },
            { "layers": ["left"], "flipX": true },
            { "layers": [{ "layer": "left", "dx": 1, "palette": "swap" }], "dx": 2, "dy": -1, "hold": 2 }
        ] }
        """#)
    let c = try #require(character)
    let opts = RenderOptions(showEmote: false)
    let ox = 10, oy = 14

    let f0 = SpriteRenderer.renderBuffer(c, state: .idle, time: 0, options: opts)
    #expect(rgba(f0, ox, oy) == SIMD4(0, 0, 0, 1))           // outline
    #expect(rgba(f0, ox + 1, oy + 1) == SIMD4(0, 1, 0, 1))   // dot overlay on top
    #expect(rgba(f0, ox + 2, oy + 1) == SIMD4(1, 0, 0, 1))   // body red
    #expect(rgba(f0, ox - 1, oy) == .zero)                    // outside the sprite

    let f1 = SpriteRenderer.renderBuffer(c, state: .idle, time: 1, options: opts)
    #expect(rgba(f1, ox + 2, oy + 1) == SIMD4(0, 0, 1, 1))   // palette swap

    let f2 = SpriteRenderer.renderBuffer(c, state: .idle, time: 2, options: opts)
    #expect(rgba(f2, ox + 3, oy) == SIMD4(1, 0, 0, 1))       // flipped to the right edge
    #expect(rgba(f2, ox, oy) == .zero)

    for t in [3.0, 4.0] {  // hold 2
        let f3 = SpriteRenderer.renderBuffer(c, state: .idle, time: t, options: opts)
        #expect(rgba(f3, ox + 3, oy - 1) == SIMD4(0, 0, 1, 1))  // ref dx 1 + frame dx 2, dy -1, ref palette
    }
    let wrapped = SpriteRenderer.renderBuffer(c, state: .idle, time: 5, options: opts)
    #expect(wrapped.pixels == f0.pixels)

    // Reduce Motion drops frame offsets; a layer's own palette still applies.
    let reduced = SpriteRenderer.renderBuffer(c, state: .idle, time: 3, options: RenderOptions(showEmote: false, reduceMotion: true))
    #expect(rgba(reduced, ox + 1, oy) == SIMD4(0, 0, 1, 1))
    // …but per-frame palettes are dropped.
    let reducedSwap = SpriteRenderer.renderBuffer(c, state: .idle, time: 1, options: RenderOptions(showEmote: false, reduceMotion: true))
    #expect(rgba(reducedSwap, ox + 2, oy + 1) == SIMD4(1, 0, 0, 1))
}

@Test func translucentColorsBlend() throws {
    var buffer = PixelBuffer(width: 1, height: 1)
    buffer.blend(0, 0, RGBA(r: 0, g: 0, b: 1, a: 1))
    buffer.blend(0, 0, try #require(RGBA(hex: "#ff000080")))
    let a = Float(0x80) / 255
    #expect(abs(buffer.pixels[0].x - a) < 0.0001)
    #expect(abs(buffer.pixels[0].z - (1 - a)) < 0.0001)
    #expect(buffer.pixels[0].w == 1)
}

@Test func motionIsPixelSnappedAndBounded() {
    for kind in [MotionKind.float, .bob, .hop, .sway, .shake] {
        let motion = Motion(kind: kind, amplitude: 2, period: 1.3)
        for t in stride(from: -3.0, to: 3.0, by: 0.05) {
            let (dx, dy) = SpriteRenderer.offset(for: motion, time: t)
            #expect(abs(dx) <= 2 && abs(dy) <= 2, "\(kind) t=\(t)")
            if kind == .bob || kind == .hop { #expect(dy <= 0) }
            if kind == .sway || kind == .shake { #expect(dy == 0) } else { #expect(dx == 0) }
        }
    }
    #expect(SpriteRenderer.offset(for: nil, time: 1) == (0, 0))
}

@Test func motionMovesTheWholeSpriteUnlessReduced() throws {
    let (character, _) = makeCharacter(animations: #""idle": { "fps": 1, "frames": [["body"]], "motion": { "type": "sway", "amplitude": 2, "period": 2 } }"#)
    let c = try #require(character)
    let still = RenderOptions(showEmote: false, reduceMotion: true)
    let a = SpriteRenderer.renderBuffer(c, state: .idle, time: 0.5, options: .init(showEmote: false))
    #expect(rgba(a, 12, 14) == SIMD4(0, 0, 0, 1))  // swayed right by 2
    #expect(SpriteRenderer.renderBuffer(c, state: .idle, time: 0.5, options: still).pixels
            == SpriteRenderer.renderBuffer(c, state: .idle, time: 0, options: still).pixels)
}

@Test func accentsAreDeterministicAndSpaced() {
    let accent = Accent(seed: 42, refs: [], palettes: [], minInterval: 2, maxInterval: 5, duration: 0.2, chance: 1)
    var starts: [Double] = []
    var wasActive = false
    for i in 0..<20_000 {
        let t = Double(i) * 0.01
        let active = SpriteRenderer.isActive(accent, time: t)
        #expect(active == SpriteRenderer.isActive(accent, time: t))
        if active && !wasActive { starts.append(t) }
        wasActive = active
    }
    #expect(starts.count >= 30 && starts.count <= 101)
    for (a, b) in zip(starts, starts.dropFirst()) {
        #expect(b - a >= 2 - 0.011 && b - a <= 8 + 0.011, "gap \(b - a)")
    }
    let never = Accent(seed: 1, refs: [], palettes: [], minInterval: 1, maxInterval: 1, duration: 0.5, chance: 0)
    #expect(!(0..<1000).contains { SpriteRenderer.isActive(never, time: Double($0) * 0.01) })
}

@Test func particlesAreDeterministicAndOnlyWhenMotionAllowed() throws {
    let (character, _) = makeCharacter(animations: #""idle": { "fps": 1, "frames": [["dot"]], "particles": ["spark"] }"#)
    let c = try #require(character)
    let opts = RenderOptions(showEmote: false)
    let a = SpriteRenderer.renderBuffer(c, state: .idle, time: 12.345, options: opts)
    let b = SpriteRenderer.renderBuffer(c, state: .idle, time: 12.345, options: opts)
    #expect(a.pixels == b.pixels)
    let lit = { (buffer: PixelBuffer) in buffer.pixels.filter { $0.w > 0 }.count }
    #expect(lit(a) > 1)
    let reduced = SpriteRenderer.renderBuffer(c, state: .idle, time: 12.345, options: .init(showEmote: false, reduceMotion: true))
    #expect(lit(reduced) == 1)
}

@Test func emotesFollowStateAndCanBeOverridden() throws {
    let (character, _) = makeCharacter(animations: #"""
        "idle": { "fps": 1, "frames": [["body"]] },
        "happy": { "fps": 1, "frames": [["body"]], "emote": "none" },
        "talking": { "fps": 1, "frames": [["body"]], "emote": "alert" }
        """#)
    let c = try #require(character)
    func emotePixels(_ state: AvatarState) -> Int {
        let with = SpriteRenderer.renderBuffer(c, state: state, time: 0.2, options: .init())
        let without = SpriteRenderer.renderBuffer(c, state: state, time: 0.2, options: .init(showEmote: false))
        return zip(with.pixels, without.pixels).filter { $0 != $1 }.count
    }
    #expect(emotePixels(.idle) == 0)
    #expect(emotePixels(.happy) == 0)       // overridden to none
    #expect(emotePixels(.talking) > 0)      // overridden to alert
    for state in [AvatarState.thinking, .working, .alert, .waiting, .sleeping] {
        #expect(emotePixels(state) > 0, "\(state) falls back to idle's art but keeps its own emote")
    }
}

@Test func stableHashIsStable() {
    #expect(StableHash.string("") == 0xcbf2_9ce4_8422_2325)  // FNV-1a offset basis: no per-process seeding
    #expect(StableHash.string("a") != StableHash.string("b"))
    let u = StableHash.unit(7, 1, 2, 3)
    #expect(u >= 0 && u < 1)
    #expect(u == StableHash.unit(7, 1, 2, 3))
}

// MARK: - Library

@Test func userCharactersOverrideBundledOnes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-sprites-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let custom = """
    { "id": "zeus", "name": "My Zeus", "size": [1, 1],
      "canvas": { "size": [1, 1], "origin": [0, 0], "anchor": [0, 1] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": ["k"] } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]] } } }
    """
    try Data(custom.utf8).write(to: dir.appendingPathComponent("zeus.json"))
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
    try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))

    let library = CharacterLibrary.load(userDirectory: dir)
    #expect(library.character(id: "zeus")?.name == "My Zeus")
    #expect(library.characters.filter { $0.id == "zeus" }.count == 1)
    #expect(library.issues.contains { $0.contains("broken.json") && $0.contains("error") })
    #expect(!library.issues.contains { $0.contains("notes.txt") })

    // Plan order for bundled characters, then user characters by name.
    let extra = { (id: String, name: String) in """
    { "id": "\(id)", "name": "\(name)", "size": [1, 1], "canvas": { "size": [1, 1], "origin": [0, 0], "anchor": [0, 1] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": ["k"] } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]] } } }
    """ }
    try Data(extra("zz-custom", "Aardvark").utf8).write(to: dir.appendingPathComponent("a.json"))
    try Data(extra("aa-custom", "Zebra").utf8).write(to: dir.appendingPathComponent("b.json"))
    let ordered = CharacterLibrary.load(userDirectory: dir).characters.map(\.id)
    #expect(ordered == CharacterLibrary.bundledOrder + ["zz-custom", "aa-custom"])

    let missing = CharacterLibrary.load(userDirectory: dir.appendingPathComponent("nope"))
    #expect(missing.issues.isEmpty)
    #expect(missing.character(id: "zeus")?.name == "Zeus")
}
