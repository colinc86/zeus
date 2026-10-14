# Zeus Sprite Format (v1)

Characters are JSON files: one character per file, no code. Bundled characters live in `Packages/ZeusKit/Sources/ZeusSprites/Characters/`. Users can drop their own into `~/Library/Application Support/Zeus/Characters/` (or use Settings → Character → **Import Character…**), and a user file with the same `id` replaces the bundled one. The app reloads that folder whenever a file in it changes.

Ids starting with `_` are reserved: the loader skips those files without reporting them. `Example Character.json` (Settings → Character → **Open Example**, `CharacterExample` in ZeusSprites) uses `"_example"`, and its notes are `"_help"` / `"_help_<section>"` strings, which the decoder ignores.

Check your work with:

```sh
zeus-sprites validate [dir]                                 # errors and warnings, per file
zeus-sprites sheet out.png --dir <dir> --scale 6 --guides  # every state × time samples (guides mark the anchor)
zeus-sprites gif out.gif --dir <dir> --character <id>      # every state animating side by side
zeus-sprites roster out.png --dir <dir>                     # every character in idle/alert/happy at its preferredScale
```

Rendering is a **pure function of `(character, state, time)`**. There's no simulation state: blinks, particles and shakes are all derived from the clock with a stable hash. So the Mac and iOS draw identical frames, and any frame can be reproduced exactly.

---

## 1. Coordinates

```
canvas (constant per character) ─────────────────┐
│  origin ─► ┌───── size (the art box) ─────┐     │
│            │ layers are placed in here      │     │
│            │ (sprite space: 0,0 = top-left) │     │
│            └────────────────────────────────┘     │
│                         ▲ anchor ("feet")         │
└───────────────────────────────────────────────────┘
```

- **Sprite space** is the coordinate system for layers, particles and `emote.at`. `(0,0)` is the top-left of the art box, and `y` grows downward. Layers may sit at negative coordinates or beyond `size`, as long as they stay inside the canvas.
- The **canvas** is the image the renderer returns. Its size never changes between states or frames, so the app's panel never resizes. Leave room in it for motion, raised props, particles and emotes. The validator warns when an animation can draw outside it.
- **`canvas.origin`** is where sprite-space `(0,0)` sits inside the canvas.
- **`preferredScale`** is how many points per pixel the character looks best at. The app multiplies it by the user's size setting (CONTRACT §6). Pick it so characters look about the same size on screen: roughly 90–110 pt of visible body.
- **`canvas.anchor`** is the character's "feet" point in canvas pixels. The app keeps it fixed on screen. `y` may equal the canvas height, meaning the line just under the last row.

## 2. Top level

```jsonc
{
  "format": 1,                       // optional; files newer than the renderer are rejected
  "id": "zeus",                      // letters, digits, - and _; same id in the user dir overrides
  "name": "Zeus",
  "summary": "King of the gods…",    // one line, shown in the character picker
  "size": [48, 46],                  // art box, in pixels
  "preferredScale": 3,               // optional (1…16, default 4): points per pixel it looks best at
  "canvas": { "size": [48, 56], "origin": [0, 7], "anchor": [24, 53] },
  "emote": { "at": [22, 9] },        // bottom-center of the emote glyph, sprite space (default: top-center)
  "palette":  { … },                 // §3
  "palettes": { … },                 // §3 named overrides
  "layers":   { … },                 // §4
  "particles":{ … },                 // §7
  "animations": { … }                // §5, keyed by avatar state; "idle" is required
}
```

## 3. Palettes

- **`palette`** maps a single character to a color: `"#rrggbb"`, or `"#rrggbbaa"` for translucency. `.` and space are reserved for transparent pixels.
- **`palettes`** holds named, partial overrides of `palette`. Each one only lists the keys it changes:

  ```json
  "palettes": {
    "glow":  { "o": "#fff38a", "h": "#ffffff" },
    "fade":  { "w": "#f6f4ffb0" },
    "night": { "c": "#dfe5f5", "C": "#b7c3e3" }
  }
  ```

  Overrides stack in a fixed order. Later ones win:
  1. the animation's `palette`
  2. the frame's `palette`
  3. palettes from any active accents (§6)
  4. the layer reference's `palette`

  Wherever a palette is accepted, you can give either one name or a list of names, e.g. `"palette": ["night", "glow"]`.

Use overrides for candle flicker, a glowing orb, lightning flashes, semi-transparent fades, night tints and glowing eyes, so the art never has to be redrawn.

## 4. Layers

```json
"layers": {
  "head":  { "x": 8, "y": 10, "rows": ["..kkkk..", ".kwwwwk.", "…"] },
  "blink": { "x": 18, "y": 18, "rows": ["ssssssssssss", "skksssssskks"] }
}
```

- `rows` are strings of palette keys, all the same length. `.` is transparent.
- `x` and `y` default to 0. They place the layer in sprite space, so a small **overlay** (eyes, mouth, a raised arm) sits exactly where it belongs and only stores the pixels it changes.
- To cover something up, paint over it. A blink overlay, for example, paints skin over the open eyes. Transparent pixels never erase.

**Layer references** appear in frames, `base`, `over` and accents. A reference is either a name, or an object that adjusts that one use of the layer:

```jsonc
"head"
{ "layer": "head", "dx": 0, "dy": 1, "flipX": false, "flipY": false, "palette": "glow" }
```

`flipX` / `flipY` mirror the layer within its own bounds. `dx` / `dy` nudge it.

## 5. Animations

Animations are keyed by avatar state: `idle, talking, thinking, working, alert, waiting, happy, sleeping`.

- **`idle` is required.** Any other state you leave out falls back along `working → thinking → idle`, `waiting → alert → idle`, and everything else `→ idle`.
- Even when a state falls back, its **emote** is still its own. A character that only draws `idle` still shows "…" when thinking.

```jsonc
"working": {
  "fps": 8,                                  // ticks per second (0 < fps ≤ 60)
  "palette": "storm",                        // optional, whole-animation override
  "motion": { "type": "bob", "amplitude": 1, "period": 0.5 },
  "base":  ["torso", "cloud", "head"],       // drawn first, every frame
  "frames": [                                // one per tick, looping
    ["boltUp", "armRUp"],                    // short form: a list of layer references
    { "layers": ["boltUp", "armRUp"], "palette": "glow", "hold": 2, "dx": 0, "dy": -1, "flipX": false }
  ],
  "over":  ["fist"],                         // drawn after the frame's layers, every frame
  "particles": ["sparks"],                   // §7
  "particleFPS": 6,                          // optional: step particle time at this rate (§7)
  "accents": [ … ],                          // §6
  "emote": "none"                            // optional: "none" or an emote name (§8)
}
```

**Draw order:** behind-particles → `base` → frame layers → `over` → accent layers → particles → emote.

**Frames**
- `hold` is how many ticks the frame stays on screen (default 1). For example, `fps: 4` with a frame holding 10 ticks stays for 2.5 s.
- `dx` / `dy` shift the whole sprite for that frame, for hops, squash and recoil.
- `flipX` mirrors the whole sprite around the art box.

**Motion** (`motion.type`) adds procedural movement to the whole sprite. Offsets are rounded to whole pixels so the art stays crisp. `amplitude` is in pixels and `period` in seconds.

| type | movement |
|---|---|
| `float` | up and down, sinusoidal (`±amplitude`) |
| `bob` | dips up and back (`0…-amplitude`) |
| `hop` | bounces: \|sin\| arcs, one hop per `period` |
| `sway` | side to side (`±amplitude`) |
| `shake` | random horizontal jitter, a new offset every `period` |
| `none` | nothing |

State changes cut over on the next rendered frame, with no transitions (CONTRACT §6).

## 6. Accents: occasional moments

Some things should happen now and then rather than on a loop: a blink, a glance, a glint, a lightning flash. Accents do this deterministically.

```jsonc
"accents": [
  { "layers": ["eyesBlink"], "every": [2.4, 5.0], "duration": 0.14 },
  { "palette": "flash", "every": [1.2, 2.6], "duration": 0.09, "chance": 0.8 }
]
```

- Time is cut into slots of `every[1]` seconds, and each slot has one event at a hashed offset. Consecutive events therefore start between `every[0]` and `2·every[1] − every[0]` seconds apart.
- `chance` (default 1) lets an event skip some slots.
- While an accent is active, its `layers` are drawn on top and its `palette` applies to the whole sprite.

## 7. Particles

```jsonc
"particles": {
  "sparks": {
    "colors": ["h", "o", "x"],       // palette keys; the color steps through the list over the particle's life
    "area": [34, 21, 6, 4],          // spawn rect [x, y, w, h], sprite space
    "velocity": [0, -5],             // px/s
    "spread": [6, 4],                // ± random velocity per particle
    "gravity": [0, 0],               // px/s²
    "life": 0.6,                     // seconds
    "count": 2,                      // live particles (0…64)
    "size": 1,                       // square size in px
    "behind": false,                 // draw before the layers (e.g. wisps emerging from behind a cloud)
    "attached": true                 // follow the sprite's motion/frame offsets (false = stay in place)
  }
}
```

**`particleFPS`** (per animation, optional, 0 < fps ≤ 60) steps particle time, so the particles move in discrete updates at that rate rather than continuously.
- Use it for **ambient** particles (drifting wisps, embers, spores, idle sparks) in calm states. For example, `6` repeats each particle frame twice at the app's 12 Hz, which halves raster work with no visible loss at pixel scale.
- Leave it out for energetic states (working, alert, happy), where smooth 12 Hz motion reads better.
- Rule of thumb: fine when particles move ≤ 12 px/s, i.e. ≤ 2 px per step at 6 Hz.
- The bundled roster uses `6` on every idle, talking, thinking, waiting and sleeping animation that has particles.

Particles are spread evenly through their lifetime. Each one gets a new position and velocity from a stable hash every cycle, so particles are a pure function of time. Their colors resolve through the current palette, so palette swaps recolor them too.

## 8. Emotes

The renderer draws a small outlined glyph for most states. Characters don't draw these themselves.

| state | emote | animation |
|---|---|---|
| thinking | `thinking`: "…" | dots appear one by one |
| working | `working`: gear | turns |
| alert | `alert`: "!" | bounces |
| waiting | `waiting`: "?" | tilts |
| happy | `happy`: ♥ | heartbeat |
| sleeping | `sleeping`: z z | drift up and fade |
| idle, talking | none | |

- The glyph is placed with its bottom-center at `emote.at`, and follows the sprite's motion.
- Leave about 11 × 12 px above `emote.at` inside the canvas (13 × 13 for large emotes); the validator checks this.
- `"emote": { "at": [x, y], "size": "large" }` draws a larger glyph set (about 1.4×). Use it for a character drawn at a small `preferredScale` (Zeus, at 3), so its emotes come out about as big on screen as the rest of the roster's. The test `emotesAreAboutTheSameSizeOnScreenAcrossTheRoster` keeps the spread within 1.4×.
- Keep emotes clear of the app's unread badge (top-right of the art) and warning marker (top-left): center them over the head. `theWarningMarkerAndBadgeNeverCoverTheAlertEmote` checks every bundled character at every avatar size.
- Make the silhouette read on a dark desktop: a light rim, or a dark outline around a lighter body (`silhouettesReadOnADarkDesktop`).
- An animation can set `"emote": "none"` or name a different emote. That override only applies when the animation is used for its own state.
- The app can hide emotes with `RenderOptions.showEmote`.

## 9. Reduce Motion

With `RenderOptions.reduceMotion`, the renderer drops:
- procedural motion
- frame `dx` / `dy`
- particles
- frame and accent palette swaps (flicker, flashes)

Emotes hold still. Frame layer changes (blinks, mouths) and the animation's own palette still play, so the character stays expressive without moving around.

## 10. Validation

`zeus-sprites validate` and `CharacterLibrary` run the same checks.

**Errors** (the file is skipped):
- bad JSON
- unknown palette keys, layers, palettes or particle systems
- ragged rows
- bad colors
- missing `idle`
- an unknown state, motion type or emote
- a canvas that can't contain the art box

**Warnings** (the file still loads):
- art or emotes that could be clipped by the canvas
- empty layers
- a duplicate `id` within one directory

## 11. Tips

- Keep `base` for what never changes, `frames` for what does, and `over` for things that must sit on top, like a fist gripping a prop.
- Use overlays (eyes, mouths, arms) instead of redrawing the whole character per frame.
- Give `idle` life without a busy loop: a gentle `float`, a blink accent, a rare glance, and one ambient particle.
- Make each state readable *without* its emote. The emote confirms the state; it shouldn't be the only thing showing it.
