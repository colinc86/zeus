import CoreGraphics
import Foundation
import Testing
import ZeusProtocol
@testable import ZeusSprites

private func bytes(_ image: CGImage) -> [UInt8] {
    (image.dataProvider?.data as Data?).map(Array.init) ?? []
}

private let library = CharacterLibrary.load(userDirectory: nil)
private let optionSets = [RenderOptions(), RenderOptions(showEmote: false, reduceMotion: true)]
/// A 12 Hz timeline (as the app samples it) over 4 s, offset so accents and particle cycles vary.
private let timeline = (0..<48).map { 1000.0 + Double($0) / 12 }

@Test(arguments: AvatarState.allCases)
func equalSignaturesRenderIdenticalPixels(state: AvatarState) {
    for character in library.characters {
        for options in optionSets {
            var seen: [SpriteFrameSignature: [UInt8]] = [:]
            for t in timeline {
                let signature = SpriteRenderer.signature(character, state: state, time: t, options: options)
                let pixels = bytes(SpriteRenderer.render(character, state: state, time: t, options: options))
                if let earlier = seen[signature] {
                    #expect(earlier == pixels, "\(character.id) \(state) t=\(t): same signature, different pixels")
                } else {
                    seen[signature] = pixels
                }
            }
        }
    }
}

/// The converse ("pixels change ⇒ signature changes") follows from the test above. This bounds the
/// other direction: signature changes without a visible change (particles behind the art) are rare.
@Test func signatureChangesAreMostlyVisible() {
    var changes = 0, spurious = 0
    for character in library.characters {
        for state in AvatarState.allCases {
            var previous: (SpriteFrameSignature, [UInt8])?
            for t in timeline {
                let signature = SpriteRenderer.signature(character, state: state, time: t)
                if let previous, previous.0 != signature {
                    changes += 1
                    if bytes(SpriteRenderer.render(character, state: state, time: t)) == previous.1 { spurious += 1 }
                }
                previous = (signature, bytes(SpriteRenderer.render(character, state: state, time: t)))
            }
        }
    }
    #expect(changes > 0)
    #expect(Double(spurious) / Double(changes) < 0.1, "\(spurious) of \(changes) signature changes were invisible")
}

@Test func signatureIsStableAndCheap() {
    let zeus = library.character(id: "zeus")!
    let a = SpriteRenderer.signature(zeus, state: .idle, time: 12.34)
    #expect(a == SpriteRenderer.signature(zeus, state: .idle, time: 12.34))
    #expect(a != SpriteRenderer.signature(zeus, state: .idle, time: 12.34, options: RenderOptions(showEmote: true, reduceMotion: true)))
    #expect(a != SpriteRenderer.signature(zeus, state: .working, time: 12.34))
}

@Test func cacheReturnsTheSameImageUntilTheSignatureChanges() throws {
    let zeus = try #require(library.character(id: "zeus"))
    let cache = SpriteFrameCache()
    var last: CGImage?
    var lastSignature: SpriteFrameSignature?
    for t in timeline {
        let image = cache.image(for: zeus, state: .sleeping, time: t)
        let signature = SpriteRenderer.signature(zeus, state: .sleeping, time: t)
        if let last, let lastSignature {
            #expect((image === last) == (signature == lastSignature), "t=\(t)")
        }
        // The cached image is exactly what render() produces.
        #expect(bytes(image) == bytes(SpriteRenderer.render(zeus, state: .sleeping, time: t)))
        last = image; lastSignature = signature
    }
    let distinct = Set(timeline.map { SpriteRenderer.signature(zeus, state: .sleeping, time: $0) }).count
    #expect(cache.rasterizedCount <= distinct)
}

@Test func reduceMotionFrameOnlyAnimationsRepeatFromCache() throws {
    // A frame-only cycle (Reduce Motion, no emote) revisits the same signatures, so a second lap is free.
    let ghost = try #require(library.character(id: "ghost"))
    let cache = SpriteFrameCache()
    let options = RenderOptions(showEmote: false, reduceMotion: true)
    for t in timeline { _ = cache.image(for: ghost, state: .idle, time: t, options: options) }
    let firstLap = cache.rasterizedCount
    for t in timeline { _ = cache.image(for: ghost, state: .idle, time: t, options: options) }
    #expect(cache.rasterizedCount == firstLap)
    #expect(firstLap < timeline.count / 2)    // 3 tail frames × blink/glance accents, not one raster per tick
}

@Test func cacheIsBounded() throws {
    let zeus = try #require(library.character(id: "zeus"))
    let cache = SpriteFrameCache(imageCapacity: 2, stackCapacity: 1)
    let times = [1000.0, 1000.5, 1001.0]
    for t in times { _ = cache.image(for: zeus, state: .working, time: t) }
    let misses = cache.rasterizedCount
    _ = cache.image(for: zeus, state: .working, time: times[0])          // evicted (capacity 2): rasterized again
    #expect(cache.rasterizedCount == misses + 1)
    cache.removeAll()
    #expect(cache.rasterizedCount == 0)
}

@Test func overridingCharacterWithSameIDChangesTheSignature() throws {
    let json = { (color: String) in """
    { "id": "zeus", "name": "Zeus", "size": [2, 2], "canvas": { "size": [2, 2], "origin": [0, 0], "anchor": [1, 2] },
      "palette": { "k": "\(color)" }, "layers": { "a": { "rows": ["kk", "kk"] } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]] } } }
    """ }
    let red = try #require(SpriteCharacter.load(data: Data(json("#ff0000").utf8), source: "a").character)
    let blue = try #require(SpriteCharacter.load(data: Data(json("#0000ff").utf8), source: "b").character)
    #expect(red.id == blue.id)
    #expect(SpriteRenderer.signature(red, state: .idle, time: 0) != SpriteRenderer.signature(blue, state: .idle, time: 0))
}

@Test func refreshIntervalReflectsWhatCanChange() throws {
    let zeus = try #require(library.character(id: "zeus"))
    #expect(SpriteRenderer.refreshInterval(zeus, state: .idle) == SpriteRenderer.proceduralInterval)
    let staticJSON = """
    { "id": "rock", "name": "Rock", "size": [1, 1], "canvas": { "size": [1, 1], "origin": [0, 0], "anchor": [0, 1] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": ["k"] } },
      "animations": { "idle": { "fps": 4, "frames": [["a"]] } } }
    """
    let rock = try #require(SpriteCharacter.load(data: Data(staticJSON.utf8), source: "rock").character)
    #expect(SpriteRenderer.refreshInterval(rock, state: .idle) == nil)              // one frame, nothing moves
    #expect(SpriteRenderer.refreshInterval(rock, state: .thinking) == 1.0 / 3)      // the "…" emote animates
    #expect(SpriteRenderer.refreshInterval(rock, state: .thinking, options: .init(showEmote: true, reduceMotion: true)) == nil)
    let blinker = """
    { "id": "blink", "name": "Blink", "size": [1, 1], "canvas": { "size": [1, 1], "origin": [0, 0], "anchor": [0, 1] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": ["k"] } },
      "animations": { "idle": { "fps": 2, "frames": [["a"], []] } } }
    """
    let b = try #require(SpriteCharacter.load(data: Data(blinker.utf8), source: "b").character)
    #expect(SpriteRenderer.refreshInterval(b, state: .idle, options: .init(showEmote: false, reduceMotion: true)) == 0.5)
}

private func particleCharacter(fps: String) throws -> SpriteCharacter {
    let json = """
    { "id": "sparkler", "name": "Sparkler", "size": [8, 8], "canvas": { "size": [8, 8], "origin": [0, 0], "anchor": [4, 8] },
      "palette": { "k": "#000000", "y": "#ffff00" }, "layers": { "a": { "rows": ["k"] } },
      "particles": { "s": { "colors": ["y"], "area": [2, 6, 4, 1], "velocity": [0, -3], "life": 2, "count": 2 } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]], "particles": ["s"]\(fps) } } }
    """
    return try #require(SpriteCharacter.load(data: Data(json.utf8), source: "sparkler").character)
}

@Test func particleFPSStepsParticleTime() throws {
    let stepped = try particleCharacter(fps: #", "particleFPS": 6"#)
    let smooth = try particleCharacter(fps: "")
    let options = RenderOptions(showEmote: false)
    // Within one 1/6 s step the stepped frame can't change; the smooth one eventually does.
    let base = 1000.0                                   // a step boundary (1000 × 6 is whole)
    let within = [base, base + 0.05, base + 0.1, base + 0.16]
    #expect(Set(within.map { SpriteRenderer.signature(stepped, state: .idle, time: $0, options: options) }).count == 1)
    #expect(SpriteRenderer.signature(stepped, state: .idle, time: base, options: options)
            != SpriteRenderer.signature(stepped, state: .idle, time: base + 1, options: options))
    #expect(Set((0..<12).map { SpriteRenderer.signature(smooth, state: .idle, time: base + Double($0) / 12, options: options) }).count > 1)
    // Stepped particles are the smooth ones sampled at the step start.
    #expect(SpriteRenderer.signature(stepped, state: .idle, time: base + 0.1, options: options).particles
            == SpriteRenderer.signature(smooth, state: .idle, time: base, options: options).particles)
    #expect(SpriteRenderer.refreshInterval(stepped, state: .idle, options: options) == 1.0 / 6)
    #expect(SpriteRenderer.refreshInterval(smooth, state: .idle, options: options) == SpriteRenderer.proceduralInterval)
}

@Test func particleFPSIsValidated() {
    let json = """
    { "id": "bad", "name": "Bad", "size": [1, 1], "canvas": { "size": [1, 1], "origin": [0, 0], "anchor": [0, 1] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": ["k"] } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]], "particleFPS": 0 } } }
    """
    let (character, issues) = SpriteCharacter.load(data: Data(json.utf8), source: "bad.json")
    #expect(character == nil)
    #expect(issues.contains { $0.message.contains("particleFPS") })
}

@Test func ambientStatesUseSteppedParticles() throws {
    let zeus = try #require(library.character(id: "zeus"))
    #expect(zeus.model.animations[.idle]?.particleFPS == 6)
    #expect(zeus.model.animations[.working]?.particleFPS == nil)    // energetic states keep full rate
}
