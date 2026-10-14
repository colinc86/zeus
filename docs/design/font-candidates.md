# Pixel Font Spike (D9)

> **Decision (2026-10-11):** the human picked **Departure Mono**. It was adopted as the bundled pixel font in D10 (16.5 pt titles, 11 pt text). Pixelify Sans was removed.

**Problem.** In Pixelify Sans (the bundled font at the time), "Z" and "2" are nearly the same glyph, and so are "0" and "O" and "8" and "B". The result is misreadings, not just a style issue. See `font-candidates.png`, first column:

| Written | Reads as |
|---|---|
| Zeus | **2eus** |
| +2 more | **+8 more** |
| 62% | **68%** |
| 8:42 | **8:48** |

**Render:** `font-candidates.png` shows each font on the same UI sample through the real ZeusDesign components (`zeus-sprites fonts`): "Zeus" plus the confusable glyphs, the count/shortcut/percent row, the badges, a peek bubble, a thread and the composer. It's dark theme, 2× render.

## Measured distinctness

Each pair is rasterized from the font's outlines at the same origin. The score is the share of differing pixels: 0 = identical, and higher is more distinct.

| Font | Z/2 | S/5 | 0/O | 1/l | l/I | 8/B | Lowercase | ⌘ | Pixel grid |
|---|---|---|---|---|---|---|---|---|---|
| Pixelify Sans (current) | **0.10** | 0.31 | **0.00** | 0.92 | 0.86 | **0.09** | yes | no | off-grid |
| **Departure Mono** | **0.52** | 0.22 | 0.14 (dotted 0) | 0.24 | 0.13 | 0.14 | yes | yes | 11 px/em |
| Monocraft | 0.39 | 0.12 | 0.16 | 0.62 | 0.59 | 0.47 | yes | yes | 18 px/em |
| VT323 | 0.39 | 0.38 | 0.44 | 0.13 | 0.11 | 0.49 | yes | no | off-grid |
| Press Start 2P | 0.23 | 0.34 | 0.30 | 0.11 | 0.10 | 0.30 | yes | no | 8 px/em |

Rejected after measuring:
- Jersey 10/15: l = I (0.00).
- DotGothic16: 0 = O (0.00).
- Micro 5: S = 5 and 0 = O.
- Silkscreen: no lowercase.
- Tiny5: an experimental five-axis variable font.

## Recommendation: Departure Mono

It has the clearest separation exactly where Pixelify fails: Z/2 is 5× more distinct, and the dotted zero fixes 0/O. Its 11 px/em grid lands on our sizes, so it's crisp with whole-pixel strokes at 11 pt (body, captions, buttons) and 16.5 pt (titles). It includes ⌘, is OFL 1.1, and is actively maintained (Helena Zhang, v1.500).

**Tradeoffs**
- It's monospace, so text wraps about 15% sooner than proportional Pixelify.
- It has a single weight, so hierarchy comes from size and color (titles are already gold).
- At 11 pt its x-height (6 pt) matches Pixelify's at 15 pt, so it isn't visually smaller.

**Runner-up: Monocraft.** It's chunkier and reads larger (13.5 pt body), with excellent l/I/1 separation and ⌘. But it's only perfectly crisp at 9 or 18 pt, and its Minecraft styling is a stronger flavor.

**Not recommended**
- VT323: legible, but tall and thin at UI sizes, and it has no ⌘.
- Press Start 2P: too wide and heavy, and body lines collide at 8 pt.

## Adopting the pick (after the human chooses)

1. Bundle the font plus its license in `ZeusDesign/Fonts/`, replacing Pixelify Sans and its OFL file. Update `ZeusFonts.pixelFamily`, `bundledFontURL` and `licenseURL`.
2. Update `ZeusTextRole.size(for: .pixel)` to the font's crisp sizes. Departure Mono: title 16.5, body/button/caption/badge 11.
3. Drop the variable-weight code (`wghtAxis`). Keep ligatures off.
4. Re-run `ZeusComposerAlignmentTests` (placeholder alignment) and the design renders. Update `ZeusFontChoice.displayName` ("Pixel").

`ZeusFontOverride` / `\.zeusFontOverride` (added in this spike) lets any view preview a font with exact per-role sizes, without changing the bundled one.

**Sources** (license texts are in `font-candidates/`; the font binaries are not checked in):
- Departure Mono: github.com/rektdeckard/departure-mono (v1.500).
- Monocraft: github.com/IdreesInc/Monocraft (v4.2.1).
- VT323 and Press Start 2P: github.com/google/fonts (`ofl/`).

To reproduce the render, put the four font files in one folder and run `zeus-sprites fonts docs/design/font-candidates.png --fonts-dir <folder>`.
