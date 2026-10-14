# Sprite Rendering for Live Views (D13)

- **Audience:** appdev (A7).
- **Fixes:** the renderer and ZeusDesign clock performance fixes.
- **Compatibility:** `SpriteRenderer.render(_:state:time:options:)` is unchanged. It's still a pure function, now 2–5× faster.

## 1. The model: plan → signature → image

Every frame is first **planned**. The plan is cheap and touches no pixels. It records:
- the animation and frame index;
- the whole-sprite offset (motion plus the frame's dx/dy);
- the active accents;
- each particle's raster position and color;
- the emote's discrete phase;
- the options;
- the character file's fingerprint.

The plan is the **`SpriteFrameSignature`**. Rasterizing reads only the plan, never the clock. So:

> **Equal signatures ⇒ identical pixels.** This is tested exhaustively on every bundled character × state × option set × a 12 Hz timeline.
>
> Different signatures almost always mean different pixels. The exception, under 10% of changes in tests, is a particle moving behind the opaque art. That costs one redundant raster, never a wrong frame.

## 2. API (ZeusSprites)

```swift
// Unchanged: one-off frames (galleries, renders, tests).
SpriteRenderer.render(character, state: s, time: t, options: o) -> CGImage

// Cheap: what the frame at `t` is. Hashable; compare with ==.
SpriteRenderer.signature(character, state: s, time: t, options: o) -> SpriteFrameSignature

// How often to re-check (seconds), or nil if this state can never change.
SpriteRenderer.refreshInterval(character, state: s, options: o) -> TimeInterval?
SpriteRenderer.proceduralInterval   // 1/12 s: the ceiling for motion, particles and accents

// The live-view path: returns the SAME CGImage instance while the signature is unchanged.
let cache = SpriteFrameCache(imageCapacity: 24, stackCapacity: 32)   // one per on-screen sprite
cache.image(for: character, state: s, time: t, options: o) -> CGImage
cache.removeAll()                 // on character change or memory pressure
cache.rasterizedCount             // misses so far (diagnostics and tests)
```

**`refreshInterval`** is the shortest of the following:

| Source | Interval |
|---|---|
| frame tick | `1 / fps`, only if the animation has more than one frame |
| procedural motion | 1/12 s (none under Reduce Motion) |
| particles | `1 / particleFPS` (at least 1/12 s) if the animation sets it, else 1/12 s (none under Reduce Motion) |
| timed accents | `max(duration / 2, 1/12)`, capped at `1 / fps` |
| animated emote | thinking 1/3 s, alert 0.15 s, waiting 0.8 s, happy 0.12 s, working 1/8 s, sleeping 1/12 s (none under Reduce Motion) |

A `nil` result means draw once and stop. Change of state, options or character is an input change: recompute the interval.

**`SpriteFrameCache`:**
- **Image cache:** keyed by signature, LRU of `imageCapacity`. Cyclic animations (frame-only, or Reduce Motion) reuse their frames, so a second loop costs nothing.
- **Layer-stack cache:** each frame's composed layers, keyed by character, state, frame, accents and Reduce Motion, LRU of `stackCapacity`. Motion and particles are drawn on top, so stacks are reused across offsets.
- **Thread safety:** it uses a `Mutex`, so it's thread-safe. Keep one cache per on-screen sprite so "same instance" stays meaningful for that view.
- **Memory:** a Zeus frame is 10.7 KB, and a stack about 28 KB. Defaults stay under about 1.2 MB per sprite.

**Character content:** the signature includes a fingerprint of the character file's bytes. A user character that overrides a bundled `id` with different art never reuses the bundled frames. You still need to call `removeAll()` when switching characters, to free memory.

## 3. Recipe for the avatar view (A7)

Replace the 12 Hz `TimelineView(.animation(minimumInterval: 1/12))`, which re-rendered every tick, with a schedule from `refreshInterval`, and **feed SwiftUI a new image only when it changes**:

```swift
struct CharacterAnimationView: View {
    let character: SpriteCharacter
    let state: AvatarState
    let scale: Int
    let active: Bool                                   // hidden / occluded / locked / asleep → false
    let cache: SpriteFrameCache                        // owned by the shell, one per sprite
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let options = RenderOptions(reduceMotion: reduceMotion)
        let interval = SpriteRenderer.refreshInterval(character, state: state, options: options)
        Group {
            if active, let interval {
                TimelineView(.periodic(from: .distantPast, by: interval)) { context in
                    frame(cache.image(for: character, state: state, time: context.date.timeIntervalSinceReferenceDate, options: options))
                }
            } else {
                // Static: draw once (nil interval), or hold the current frame while inactive.
                frame(cache.image(for: character, state: state, time: Date().timeIntervalSinceReferenceDate, options: options))
            }
        }
    }

    private func frame(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).interpolation(.none).resizable()
            .frame(width: CGFloat(character.canvasSize.width * scale), height: CGFloat(character.canvasSize.height * scale))
    }
}
```

**Avoiding the SwiftUI update when nothing changed.** If profiling still shows `TimelineView` cost on unchanged ticks, move the clock out of the view:
- A small `@Observable` driver owns the timer (at `refreshInterval`, paused while inactive).
- On each tick it calls `cache.image(...)` and assigns `image` **only if `newImage !== image`**.
- The view then just displays `driver.image`.

That's the strongest form of P8 #1, and it costs about 30 µs per tick in Debug when nothing changed (see §5).

**Settings gallery:** give each preview its own `SpriteFrameCache` and `active: isSettingsWindowVisible`, so twelve hidden previews cost nothing.

## 4. ZeusDesign clocks (P8 #4)

- **`\.zeusAnimationsActive`** (environment, default `true`): set it per surface. Use `false` when the conversation panel is closed or occluded, the peek is hidden, or the screen is locked or asleep. While it's `false`:
  - `ZeusActivityRow` dots hold all three dots lit;
  - an indeterminate `ZeusProgressBar` holds a static stripe;
  - `ZeusPeekBubble` shows its full text.

  Under Reduce Motion, all three are always static.
- **Peek typewriter:** it uses `TimelineView(.explicit(ZeusPeekTiming.revealDates(start:total:)))`. That's one update per revealed character, and **none after the last**, so a high-priority bubble that stays up costs nothing once typed. No API change: keep passing `reveal: .typing(start:)`.
- **Typing indicator (D16):** `ZeusTypingIndicator`'s dots are a Core Animation keyframe animation, not a SwiftUI clock, so an open panel with the indicator costs about what it costs without it (10.9% → 1.05% app CPU, same conditions). Prefer this for any always-on loop that sits inside a large SwiftUI hierarchy.
- **Clocks:** the activity dots (0.3 s) and indeterminate progress (0.1 s) use periodic schedules aligned to a fixed epoch, so remounting doesn't jitter them.
- **`ZeusMarkdown.attributed`** caches by (text, font choice, built-in palette), bounded at 256 entries, so re-evaluating a bubble body doesn't re-parse markdown. A custom palette is parsed fresh.

**Still appdev's (A7):** the thread's own typewriter (`TypewriterModel` / `MessageBodyView`) and the 250 ms shell tick. Gate them on visibility the same way, and stop the model's task when `isRevealing` is false.

## 5. Measurements (M1 Pro)

Commands: `zeus-sprites bench`. The *before* numbers come from `main`'s ZeusKit, built separately and run with the same loop. All figures are µs per call on a 12 Hz timeline over idle, working and sleeping.

| Path | Debug, all 12 characters | Debug, Zeus | Release, all | Release, Zeus |
|---|---:|---:|---:|---:|
| `render()` **before** | 1,327 | 2,415 | 21.5 | 37.1 |
| `render()` **after** | 296 (4.5×) | 501 (4.8×) | 12.8 (1.7×) | 23.1 (1.6×) |
| `SpriteFrameCache.image()`, the live path | **30.5** (43×) | **141** (17×) | **4.7** (4.6×) | **16.5** (2.2×) |
| `signature()` only | 3.6 | 6.0 | 0.3 | 0.6 |

**At 12 Hz in Debug,** one Zeus avatar's raster cost drops from about **2.9% of a core to about 0.17%**. Across the roster it averages about **0.04%**, because 76% of ticks reuse the previous image. Zeus reuses less (about 1%) because his idle sparks really do move every tick; those ticks still cost only 141 µs.

**`particleFPS` (D14).** Ambient states step particles at 6 Hz, so idle frames repeat.
- **Zeus idle:** cache reuse goes from 0.3% to **42%** of 12 Hz ticks, and the live path from 94 to **58 µs per tick** in Debug.
- The remaining changes are his float motion and his blink, glance and glow accents, which are real visual changes.
- Run `zeus-sprites bench --characters zeus --states idle` to reproduce.

**What made the difference in Debug:**
- the plan and the cache: no raster when nothing changed;
- composed layer stacks, so a moving frame skips layer drawing;
- vDSP for the two whole-buffer passes (the stack composite and the float → RGBA8 conversion), which run at full speed even in unoptimized builds;
- one shared sRGB color space.

Output matches the old renderer except for the quantized z fade (to 1/16 steps) and float rounding in precomposed stacks, at most 5/255 on 0.05% of the pixels in a full roster sheet. The exact-value pixel tests are unchanged and pass.
