import CoreGraphics
import Foundation
import Synchronization
import ZeusProtocol

/// Options that change how a character renders without changing its art.
public struct RenderOptions: Sendable, Equatable, Hashable {
    /// Draw the built-in emote for the state (thinking "…", alert "!", …).
    public var showEmote = true
    /// Accessibility: drop procedural motion, per-frame offsets, particles, and per-frame or
    /// accent palette swaps (flicker, flashes), and hold emotes still. Frame changes (blinks,
    /// mouths) and the animation's own palette still apply.
    public var reduceMotion = false

    public init(showEmote: Bool = true, reduceMotion: Bool = false) {
        self.showEmote = showEmote
        self.reduceMotion = reduceMotion
    }
}

/// Everything that determines one rendered frame. **Equal signatures render identical pixels**
/// (rendering is a pure function of the signature), so a view can keep its last image while the
/// signature is unchanged. Different signatures *usually* mean different pixels; the exception is
/// a particle hidden behind the art, which changes the signature without a visible change.
///
/// Fields are internal; compare with `==`, or use it as a dictionary key.
public struct SpriteFrameSignature: Hashable, Sendable {
    /// The character file's fingerprint: a user override with the same `id` still differs.
    let content: UInt64
    let requested: AvatarState
    let resolved: AvatarState
    let options: RenderOptions
    /// Index into the animation's frames (holds collapsed).
    let frame: Int
    /// Whole-sprite offset: procedural motion plus the frame's dx/dy.
    let offsetX: Int
    let offsetY: Int
    /// Bit i set = accent i is showing.
    let accents: UInt64
    /// Each particle as it will be rasterized: system, color key and canvas position, packed.
    let particles: [Int64]
    let emote: EmotePlan?
}

/// Renders characters. Output is a pure function of `(character, state, time, options)`.
///
/// For live display, prefer `SpriteFrameCache.image(...)`: it returns the *same* `CGImage` until
/// the frame's signature changes, so an idle avatar costs a signature check per tick, not a raster.
public enum SpriteRenderer {
    /// Renders one frame into a `CGImage` of exactly `character.canvasSize` pixels.
    /// - Parameter time: seconds on any monotonic clock; only differences matter visually.
    public static func render(_ character: SpriteCharacter, state: AvatarState,
                              time: TimeInterval, options: RenderOptions = .init()) -> CGImage {
        renderBuffer(character, state: state, time: time, options: options).makeImage()
    }

    /// The frame's signature at `time`: cheap (no pixels touched). Equal signatures render identical images.
    public static func signature(_ character: SpriteCharacter, state: AvatarState,
                                 time: TimeInterval, options: RenderOptions = .init()) -> SpriteFrameSignature {
        plan(character, state: state, time: time, options: options).signature
    }

    /// How often a live view samples this state: frame ticks, timed accents, animated emotes,
    /// and procedural motion or particles. Active procedural effects use a 12 Hz ceiling.
    /// `nil` means the frame can never change (draw it once).
    ///
    /// Resting states use their declared frame and particle rates; timed accents land on that grid.
    /// Re-checking is cheap with `SpriteFrameCache`: the image only changes when the signature does.
    public static func refreshInterval(_ character: SpriteCharacter, state: AvatarState,
                                       options: RenderOptions = .init()) -> TimeInterval? {
        let c = character.model
        guard let anim = c.animations[character.resolvedState(for: state)] else { return nil }
        let resting = state == .idle || state == .sleeping
        let motionInterval = resting ? 1 / anim.fps : proceduralInterval
        var interval = Double.infinity
        if anim.frames.count > 1 { interval = min(interval, 1 / anim.fps) }
        if !options.reduceMotion {
            if anim.motion.map({ $0.kind != .none && $0.amplitude > 0 }) ?? false { interval = min(interval, motionInterval) }
            if !anim.particles.isEmpty { interval = min(interval, anim.particleFPS.map { resting ? 1 / $0 : max(1 / $0, proceduralInterval) } ?? proceduralInterval) }
        }
        for accent in anim.accents where !accent.refs.isEmpty || (!accent.palettes.isEmpty && !options.reduceMotion) {
            interval = min(interval, resting ? 1 / anim.fps : min(max(accent.duration / 2, proceduralInterval), 1 / anim.fps))
        }
        if options.showEmote, !options.reduceMotion, let kind = emoteKind(character, state: state) {
            interval = min(interval, resting ? motionInterval : emoteInterval(kind))
        }
        return interval.isFinite ? interval : nil
    }

    /// The ceiling for procedural effects (motion, particles, accents), matching the app's 12 Hz cap.
    public static let proceduralInterval: TimeInterval = 1.0 / 12

    // MARK: - Plan → rasterize

    struct Plan {
        let signature: SpriteFrameSignature
        let animation: Animation
        let frame: Frame
    }

    static func plan(_ character: SpriteCharacter, state: AvatarState, time t: TimeInterval, options: RenderOptions) -> Plan {
        let c = character.model
        let resolved = character.resolvedState(for: state)
        let anim = c.animations[resolved] ?? Animation(fps: 1, base: [], frames: [], over: [], totalTicks: 1,
                                                       palettes: [], motion: nil, particles: [], particleFPS: nil, accents: [], emote: nil)
        guard !anim.frames.isEmpty else {
            let empty = SpriteFrameSignature(content: character.contentID, requested: state, resolved: resolved, options: options,
                                             frame: -1, offsetX: 0, offsetY: 0, accents: 0, particles: [], emote: nil)
            return Plan(signature: empty, animation: anim, frame: Frame(refs: [], palettes: [], hold: 1, dx: 0, dy: 0, flipX: false))
        }

        // Frame selection: ticks advance at `fps`; each frame lasts `hold` ticks.
        let tick = Int(floorMod((t * anim.fps).rounded(.down), Double(anim.totalTicks)))
        var frameIndex = 0
        var acc = 0
        for (i, f) in anim.frames.enumerated() {
            acc += f.hold
            if tick < acc { frameIndex = i; break }
        }
        let frame = anim.frames[frameIndex]

        let motion = options.reduceMotion ? (0, 0) : offset(for: anim.motion, time: t)
        let frameOffset = options.reduceMotion ? (0, 0) : (frame.dx, frame.dy)
        let dx = motion.0 + frameOffset.0, dy = motion.1 + frameOffset.1

        var accents: UInt64 = 0
        for (i, accent) in anim.accents.enumerated() where i < 64 && isActive(accent, time: t) {
            // Under Reduce Motion an accent's palette is ignored, so a palette-only accent can't change pixels.
            if options.reduceMotion && accent.refs.isEmpty { continue }
            accents |= 1 << UInt64(i)
        }

        var particles: [Int64] = []
        // An animation's particleFPS steps particle time, so ambient particles (and frames) repeat between steps.
        let particleTime = anim.particleFPS.map { (t * $0).rounded(.down) / $0 } ?? t
        if !options.reduceMotion {
            for (order, index) in anim.particles.enumerated() {
                let system = c.particles[index]
                let origin = system.attached ? (c.origin.x + dx, c.origin.y + dy) : (c.origin.x, c.origin.y)
                for (key, x, y) in particlePositions(system, time: particleTime, origin: origin) {
                    particles.append(Int64(order) << 48 | Int64(key) << 40 | (Int64(x) & 0xFFFFF) << 20 | (Int64(y) & 0xFFFFF))
                }
            }
        }

        var emote: EmotePlan?
        if options.showEmote, let kind = emoteKind(character, state: state) {
            emote = Emotes.plan(kind, time: t, reduceMotion: options.reduceMotion)
        }

        let signature = SpriteFrameSignature(content: character.contentID, requested: state, resolved: resolved, options: options,
                                             frame: frameIndex, offsetX: dx, offsetY: dy, accents: accents,
                                             particles: particles, emote: emote)
        return Plan(signature: signature, animation: anim, frame: frame)
    }

    static func renderBuffer(_ character: SpriteCharacter, state: AvatarState,
                             time t: TimeInterval, options: RenderOptions) -> PixelBuffer {
        rasterize(character, plan(character, state: state, time: t, options: options), layers: nil)
    }

    /// Draws a plan. Uses only the plan (never the clock), which is what makes signatures sound.
    /// - Parameter layers: a precomposed layer stack for this plan's `CompositionKey`, if cached.
    static func rasterize(_ character: SpriteCharacter, _ plan: Plan, layers cached: PixelBuffer?) -> PixelBuffer {
        let c = character.model
        let s = plan.signature
        var buffer = PixelBuffer(width: c.canvas.width, height: c.canvas.height)
        guard s.frame >= 0 else { return buffer }
        let palette = resolvePalette(c, sharedPalettes(plan))

        func drawParticles(behind: Bool) {
            for packed in s.particles {
                let order = Int(packed >> 48)
                let system = c.particles[plan.animation.particles[order]]
                guard system.behind == behind else { continue }
                let key = Int((packed >> 40) & 0xFF)
                let x = Int((packed >> 20) & 0xFFFFF), y = Int(packed & 0xFFFFF)
                let px = x >= 0x80000 ? x - 0x100000 : x, py = y >= 0x80000 ? y - 0x100000 : y
                let color = palette[key]
                for yy in 0..<system.size { for xx in 0..<system.size { buffer.blend(px + xx, py + yy, color) } }
            }
        }

        drawParticles(behind: true)
        let layers = cached ?? composeLayers(character, plan)
        buffer.composite(layers, dx: s.offsetX - compositionMargin, dy: s.offsetY - compositionMargin)
        drawParticles(behind: false)
        if let emote = s.emote {
            Emotes.draw(emote, glyphs: Emotes.glyphs(large: c.largeEmotes), centerX: c.origin.x + s.offsetX + c.emoteAt.x, bottom: c.origin.y + s.offsetY + c.emoteAt.y, into: &buffer)
        }
        return buffer
    }

    // MARK: - Layer composition (cacheable)

    /// Margin around the canvas in a composed layer stack, so art that motion later shifts into view
    /// isn't clipped at composition time.
    static let compositionMargin = 16

    /// The part of a plan that the layer stack depends on: not motion, particles or emotes.
    struct CompositionKey: Hashable {
        let content: UInt64
        let resolved: AvatarState
        let reduceMotion: Bool
        let frame: Int
        let accents: UInt64
    }

    static func compositionKey(_ plan: Plan) -> CompositionKey {
        let s = plan.signature
        return CompositionKey(content: s.content, resolved: s.resolved, reduceMotion: s.options.reduceMotion, frame: s.frame, accents: s.accents)
    }

    /// All of the frame's layers (base, frame, over, active accents) with their palettes, composed at
    /// rest (no motion) into a canvas-plus-margin buffer.
    static func composeLayers(_ character: SpriteCharacter, _ plan: Plan) -> PixelBuffer {
        let c = character.model
        let m = compositionMargin
        var buffer = PixelBuffer(width: c.canvas.width + 2 * m, height: c.canvas.height + 2 * m)
        let shared = sharedPalettes(plan)
        let palette = resolvePalette(c, shared)
        let accentRefs = plan.animation.accents.enumerated().filter { plan.signature.accents & (1 << UInt64($0.offset)) != 0 }.flatMap(\.element.refs)
        for ref in plan.animation.base + plan.frame.refs + plan.animation.over + accentRefs {
            let refPalette = ref.palettes.isEmpty ? palette : resolvePalette(c, shared + ref.palettes)
            drawLayer(c, ref, flipSprite: plan.frame.flipX, palette: refPalette, originX: c.origin.x + m, originY: c.origin.y + m, into: &buffer)
        }
        return buffer
    }

    /// Palette overrides for the whole frame: the animation's, plus (unless Reduce Motion) the
    /// frame's and active accents'.
    static func sharedPalettes(_ plan: Plan) -> [Int] {
        let anim = plan.animation
        guard !plan.signature.options.reduceMotion else { return anim.palettes }
        let accents = anim.accents.enumerated().filter { plan.signature.accents & (1 << UInt64($0.offset)) != 0 }.flatMap(\.element.palettes)
        return anim.palettes + plan.frame.palettes + accents
    }

    // MARK: - Pieces

    static func emoteKind(_ character: SpriteCharacter, state: AvatarState) -> EmoteKind? {
        switch character.model.animations[state]?.emote {
        case .none?: nil
        case .glyph(let k)?: k
        case nil: EmoteKind.default(for: state)
        }
    }

    /// How often an emote's appearance can change (see `Emotes.plan`).
    static func emoteInterval(_ kind: EmoteKind) -> TimeInterval {
        switch kind {
        case .thinking: 1.0 / 3
        case .alert: 0.15
        case .waiting: 0.8
        case .happy: 0.12
        case .working: 1.0 / 8
        case .sleeping: proceduralInterval
        }
    }

    /// Pixel-snapped procedural motion offset.
    static func offset(for motion: Motion?, time t: Double) -> (Int, Int) {
        guard let m = motion else { return (0, 0) }
        let phase = 2 * Double.pi * t / m.period
        func snap(_ v: Double) -> Int { Int(v.rounded()) }
        switch m.kind {
        case .none: return (0, 0)
        case .float: return (0, snap(m.amplitude * sin(phase)))
        case .bob: return (0, -snap(m.amplitude * (0.5 - 0.5 * cos(phase))))
        case .hop: return (0, -snap(m.amplitude * abs(sin(phase / 2))))
        case .sway: return (snap(m.amplitude * sin(phase)), 0)
        case .shake:
            let step = Int((t / m.period).rounded(.down))
            return (snap((StableHash.unit(0x5EED, step) * 2 - 1) * m.amplitude), 0)
        }
    }

    /// Whether an accent is showing at `t`. Time is cut into slots of `maxInterval`; each slot
    /// has one event at a hashed offset in `[0, max - min]`, so starts are min…(2·max − min) apart.
    static func isActive(_ a: Accent, time t: Double) -> Bool {
        let slot = Int((t / a.maxInterval).rounded(.down))
        for k in [slot - 1, slot] {
            guard a.chance >= 1 || StableHash.unit(a.seed, k, 1) < a.chance else { continue }
            let start = Double(k) * a.maxInterval + StableHash.unit(a.seed, k) * (a.maxInterval - a.minInterval)
            if t >= start && t < start + a.duration { return true }
        }
        return false
    }

    static func resolvePalette(_ c: CompiledCharacter, _ overrides: [Int]) -> [RGBA] {
        var palette = c.basePalette
        for index in overrides {
            for (key, color) in c.overrides[index] { palette[Int(key)] = color }
        }
        return palette
    }

    static func drawLayer(_ c: CompiledCharacter, _ ref: LayerRef, flipSprite: Bool, palette: [RGBA],
                          originX: Int, originY: Int, into buffer: inout PixelBuffer) {
        let layer = c.layers[ref.layer]
        layer.pixels.withUnsafeBufferPointer { pixels in
            for ly in 0..<layer.height {
                for lx in 0..<layer.width {
                    let key = pixels[ly * layer.width + lx]
                    guard key != 0 else { continue }
                    let x = ref.flipX ? layer.width - 1 - lx : lx
                    let y = ref.flipY ? layer.height - 1 - ly : ly
                    var sx = layer.x + ref.dx + x
                    let sy = layer.y + ref.dy + y
                    if flipSprite { sx = c.size.width - 1 - sx }
                    buffer.blend(originX + sx, originY + sy, palette[Int(key)])
                }
            }
        }
    }

    /// Where each live particle of a system lands at `time`: (color key, canvas x, canvas y).
    static func particlePositions(_ p: ParticleSystem, time t: Double, origin: (Int, Int)) -> [(ColorKey, Int, Int)] {
        var result: [(ColorKey, Int, Int)] = []
        result.reserveCapacity(p.count)
        for i in 0..<p.count {
            // Particles are staggered evenly through their life; cycle `n` reseeds position and velocity.
            let u = t + Double(i) / Double(p.count) * p.life
            let n = Int((u / p.life).rounded(.down))
            let age = u - Double(n) * p.life
            let x0 = p.area.x + StableHash.unit(p.seed, i, n, 0) * p.area.w
            let y0 = p.area.y + StableHash.unit(p.seed, i, n, 1) * p.area.h
            let vx = p.velocity.x + (StableHash.unit(p.seed, i, n, 2) * 2 - 1) * p.spread.x
            let vy = p.velocity.y + (StableHash.unit(p.seed, i, n, 3) * 2 - 1) * p.spread.y
            let x = x0 + vx * age + 0.5 * p.gravity.x * age * age
            let y = y0 + vy * age + 0.5 * p.gravity.y * age * age
            let ramp = min(Int(age / p.life * Double(p.colors.count)), p.colors.count - 1)
            result.append((p.colors[ramp], origin.0 + Int(x.rounded(.down)), origin.1 + Int(y.rounded(.down))))
        }
        return result
    }
}

/// A live view's renderer: returns the **same `CGImage` instance** for as long as the frame's
/// signature is unchanged, and reuses composed layer stacks across frames.
///
/// Typical use (the avatar view, at the cadence from `SpriteRenderer.refreshInterval`):
/// ```swift
/// let image = cache.image(for: character, state: state, time: now, options: options)
/// // `image === previous` ⇒ nothing changed; skip the view update.
/// ```
/// Thread-safe; one cache per on-screen sprite keeps its "last image" meaningful.
public final class SpriteFrameCache: Sendable {
    private struct State {
        var images: [SpriteFrameSignature: CGImage] = [:]
        var imageOrder: [SpriteFrameSignature] = []
        var stacks: [SpriteRenderer.CompositionKey: PixelBuffer] = [:]
        var stackOrder: [SpriteRenderer.CompositionKey] = []
        var rasterized = 0
    }
    private let state = Mutex(State())
    private let imageCapacity: Int
    private let stackCapacity: Int

    /// - Parameters:
    ///   - imageCapacity: recent frames kept by signature (cyclic animations reuse them).
    ///   - stackCapacity: composed layer stacks kept (one per frame × active-accent combination).
    public init(imageCapacity: Int = 24, stackCapacity: Int = 32) {
        self.imageCapacity = max(1, imageCapacity)
        self.stackCapacity = max(1, stackCapacity)
    }

    /// The frame at `time`. Returns a previously returned image (same instance) when its signature
    /// matches; otherwise rasterizes, reusing the frame's composed layers when cached.
    public func image(for character: SpriteCharacter, state avatarState: AvatarState,
                      time: TimeInterval, options: RenderOptions = .init()) -> CGImage {
        let plan = SpriteRenderer.plan(character, state: avatarState, time: time, options: options)
        let key = plan.signature
        if let hit = state.withLock({ $0.images[key] }) { return hit }
        let stackKey = SpriteRenderer.compositionKey(plan)
        let cachedStack = state.withLock { $0.stacks[stackKey] }
        let stack = cachedStack ?? SpriteRenderer.composeLayers(character, plan)
        let image = SpriteRenderer.rasterize(character, plan, layers: stack).makeImage()
        state.withLock { s in
            s.rasterized += 1
            if cachedStack == nil {
                s.stacks[stackKey] = stack
                s.stackOrder.append(stackKey)
                if s.stackOrder.count > stackCapacity { s.stacks[s.stackOrder.removeFirst()] = nil }
            }
            if s.images[key] == nil { s.imageOrder.append(key) }
            s.images[key] = image
            if s.imageOrder.count > imageCapacity { s.images[s.imageOrder.removeFirst()] = nil }
        }
        return image
    }

    /// Frames rasterized so far (cache misses). For tests and diagnostics.
    public var rasterizedCount: Int { state.withLock { $0.rasterized } }

    /// Drops everything (e.g. on memory pressure or when the character changes).
    public func removeAll() {
        state.withLock { $0 = State() }
    }
}
