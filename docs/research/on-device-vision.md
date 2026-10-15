# On-device vision for Level 3 "Screen" (LM2-D2 spike)

**Question:** how should Zeus turn a screenshot of the front window into something safe to keep and useful to the assistant, entirely on the Mac, and what does each step cost?

**Answer in one line:** after the hard stops, each frame flows through these steps:
1. Skip the frame if it hasn't changed.
2. Read its text and remove private text, covering those lines with solid boxes.
3. Find faces by tiles, not across the whole frame, and pixellate them.
4. Describe the frame from its text plus the app name and window title, with no image going to the model.

A frame that's kept costs about 4 s of mostly accelerated work at 2560×1600. An unchanged frame costs under 0.1 s.

**Conditions:**
- M1 Pro, macOS 27.0, Xcode 27.0, Apple Intelligence on.
- Every frame is drawn by the program (`docs/research/on-device-spike/vision.swift`), never captured: a terminal, an Xcode window and a bank page in a browser, each at 1280×800 and 2560×1600.
- Face tests composite two public-domain NASA portraits (Wikimedia Commons), passed with `--faces DIR`. They're downloaded to a scratch folder and never committed.
- Timings are wall-clock medians of 5 runs after the first. First-use costs are listed separately.
- **ScreenCaptureKit capture cost was not measured.** Capturing would read the real screen, which this spike must not do. Platform should measure it in a harness that captures only a window the harness owns.

Build and run:

```sh
xcrun swiftc -O -swift-version 6 docs/research/on-device-spike/vision.swift -o vision
./vision 5 [--write OUT_DIR] [--faces DIR_OF_JPEGS]
```

## 1. Measurements

### Text (OCR, `RecognizeTextRequest`)

| Frame | `.accurate` 1280×800 | `.accurate` 2560×1600 | Yield | `.fast` |
|---|---:|---:|---|---|
| Terminal | 277–362 ms | 283–302 ms | 12 lines, 433 chars | 0 lines |
| Xcode | 286–292 ms | 277–753 ms | 14 lines, 469 chars | 0 lines |
| Browser (bank page) | 257–297 ms | 274–456 ms | 13 lines, 475 chars | 0 lines |

- **The first OCR after login takes 65–69 s** (model load). Warm it when the user turns Level 3 on.
- `.fast` found **no** lines on any frame, light or dark, so don't use it.
- Resolution barely changes the cost or yield, so OCR the frame at its native scale.

### Covering private text, then reading again

- **Which lines are covered:** the stage-1 patterns run on every OCR line (emails, tokens, card and account numbers, amounts, names). Each matching line's box, padded by 4 px, is covered. The terminal had 5 matching lines, Xcode 0 and the bank page 9.
- **Leak test:** after covering, the frame is OCR'd again, and any original match that can still be read counts as a leak.

| Cover | Leaks (terminal / Xcode / bank) |
|---|---|
| Gaussian blur, radius 8 | 0 / 0 / 0 |
| Gaussian blur, radius 20 | 0 / 0 / 0 |
| Pixellate, 16 px | 0 / 0 / 0 |
| Solid fill | 0 / 0 / 0 |

- Cost: **3.5 ms** per frame for every covered line.
- All four covers defeat re-OCR at line granularity, but blur and pixellation are reversible in principle: deblurring of known fonts is an established attack. **Use solid fill for text**, in the theme's `fieldBorder` grey, with a 1-px outline. The viewer can then show where text was removed (§3 of `PRIVACY.md`).

### Faces and people

| Method | 1280×800 | 2560×1600 | Faces found (of 2) |
|---|---:|---:|---|
| `DetectFaceRectanglesRequest`, whole frame | 22–48 ms | 39–43 ms | **0** |
| `DetectHumanRectanglesRequest`, whole frame | 33–41 ms | 36–45 ms | **0** |
| Saliency (`GenerateObjectnessBasedSaliencyImageRequest`) → faces in each region | 65–73 ms | — | 1 (the larger portrait) |
| Tiles of 512 px, 25 % overlap | 718 ms (12 tiles) | 2,081 ms (35 tiles) | 1 / **2** |
| Tiles of 384 px | 786 ms | 3,627 ms | 1 / 2 |
| Tiles of 256 px | 2,418 ms | 8,445 ms | 2 / 2 |

- **Finding: whole-frame face detection misses faces that are small relative to the frame.** The same two portraits, alone, are each detected (1 face, 1 human), but placed in a page as a 160×200 pt photo and a 64×80 pt avatar, neither is found.
- Tiles of 512 px over the native 2560×1600 frame found both in about 2 s.
- The first face request after login costs about 5.7 s.

**Recommendation:**
- Run faces on 512-px tiles of the native-resolution frame, **skipping tiles that are mostly OCR text boxes** (most code, terminal and document frames). Expect well under 1 s on typical work frames and about 2 s on photo-heavy pages.
- Pixellate each face box padded by 25 %; after that, Vision detects no face in it.
- Video calls stay a hard stop, so faces in live video never reach this step.

### "Has the frame changed?"

The test compares each frame with a redrawn identical frame, the same frame with only the clock changed, and versions scrolled by 8, 20 and 80 pt. A different app is the control. `d` is the dHash distance (64-bit) and `diff` is the mean absolute difference of a 64×40 grey thumbnail (0–255).

| Window | identical | clock only | scroll 8 pt | scroll 20 pt | scroll 80 pt | other app |
|---|---|---|---|---|---|---|
| Terminal | d 0, diff 0.00 | d 0, 0.00 | d 0, 0.60 | d 3, 1.42 | d 4, 2.05 | d 5, 6.74 |
| Xcode | d 0, 0.00 | d 0, 0.00 | d 0, 0.80 | d 1, 1.30 | d 4, 2.07 | d 20, 207.7 |
| Browser | d 0, 0.00 | d 0, 0.00 | d 1, 2.24 | d 4, 4.08 | d 13, 9.05 | d 23, 211.0 |

- **dHash alone is too coarse for text windows.**
  - An 8-pt scroll scores 0–1, so it would be wrongly called unchanged.
  - Two different dark windows (terminal vs Xcode) differ by only 5.
- **Rule:** a frame is unchanged only when **the app and window title are the same, dHash d ≤ 2, and the thumbnail diff < 0.3**. With that rule:
  - A clock tick counts as unchanged (diff 0.00).
  - Every scroll counts as changed (diff ≥ 0.60).
- **Cost:** 17 ms at 1280×800 and 70 ms at 2560×1600, almost all of it the downscale. Ask ScreenCaptureKit for a small preview size or downscale once on the GPU, and compute both values from one 64×40 thumbnail.

### The description (on-device Foundation Model, `FrameDescription`)

The model gets the OCR lines after covering, with private lines replaced by `‹redacted›`.

| Frame | (a) OCR text only | (b) OCR + app + window title | (c) covered image + app + title |
|---|---|---|---|
| Terminal | 1.7 s · "Git log output" · "Reviewing code changes and running scripts." | 1.8 s · "scripts/test.sh" · "Running automated script tests and noting results." | 2.0 s warm, 5.2 s first · "log" · "Running a command and noting an error." |
| Xcode | 1.7 s · ManagedSessionController.swift · "Debugging a session restart with conversation continuity." | 1.8 s · same file · "Debugging a session restart that failed to resume." | 2.2 s, 5.2 s first · same file · "Writing code for a session controller." |
| Bank page | 2.0 s · "Northwind Bank - Checking" · "Reviewing account information." · secrets **false** | 1.7 s · same · same · secrets **true** | 1.6 s, 4.6 s first · same · "Reviewing financial information." · secrets true |

- **(b) is the best mix.** It has the most specific activity sentences, it's as fast as the image path once warm, and it's much faster cold. No image ever goes to the model.
- The text inputs are 70–120 tokens, well inside the 4,096-token context.
- **`visibleSecrets` is unreliable as a guard:** the same page scored false in (a) and true in (b). Treat it as a *hint* that raises caution (when true, keep only the description and drop the frame), never as the thing that decides whether the frame is safe. Stage-1 patterns on OCR remain the guard.
- The description goes through the Redactor (stages 1 and 2) like any other text before storage.

### Hard stops

| Stop | API | Measured | Notes |
|---|---|---|---|
| Camera in use (video call) | CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` on each `kCMIOHardwarePropertyDevices` device | 113–134 ms for 3–5 devices; 0 running | Needs no camera permission and never opens the camera. Enumerate once and register `CMIOObjectAddPropertyListenerBlock` on each device rather than polling. Re-enumerate on device changes. |
| Presenting (mirrored display) | `CGDisplayIsInMirrorSet`, `CGDisplayMirrorsDisplay` over `CGGetOnlineDisplayList` | < 1 ms | No permission. Also treat Keynote or PowerPoint in full-screen play as presenting (frontmost bundle id plus a full-screen window). |
| Password field focused | `IsSecureEventInputEnabled()` (Carbon) | < 1 ms | Check immediately before capture and again before storing. |
| Private window, private-list app, locked screen | the Level 2 checks | — | The same as Phase A. |

## 2. Recommended pipeline and per-frame budget

On an event (app or document switch after 10 s of dwell, 5 min in the same context, return from idle, or on demand), and under the hourly cap:

| # | Step | Cost at 2560×1600 (M1 Pro) |
|---|---|---:|
| 0 | Hard stops (camera, mirroring, secure input, private window or app, lock): any one means no capture | < 1 ms; camera via listener |
| 1 | Capture the front window only (ScreenCaptureKit, `SCScreenshotManager`, window filter) | not measured (see Conditions) |
| 2 | 64×40 thumbnail → dHash + diff. If unchanged (same app and title, d ≤ 2, diff < 0.3), **stop here** | ≈ 70 ms, or less with a small capture |
| 3 | OCR, `.accurate` | ≈ 300 ms |
| 4 | Stage-1 patterns on each line → solid-fill those boxes | < 10 ms |
| 5 | Faces on 512-px tiles not covered by text → pixellate | 0.2–2.1 s |
| 6 | `FrameDescription` from (b): covered OCR text + app + title | ≈ 1.8 s |
| 7 | Redactor stages 1 and 2 on the description (batched, as in Phase A) | shared |
| 8 | If `visibleSecrets` is true or a sensitive-app rule matched: keep the description only, drop the frame. Otherwise store the covered frame (HEIC, 7 days) and the description (90 days) | — |

- **Budget:** a kept frame takes about 2.5–4.5 s of work, mostly on the Neural Engine and GPU, at `.utility` priority. An unchanged frame takes under 0.1 s.
- **At a cap of 12 kept frames an hour,** that's under 1 min of work per hour (about 1.5 % of one core averaged, idle the rest of the time).
- **Skip the model** when on battery below 30 % or in Low Power Mode. Store the covered frame with no description and describe it later on power.
- **Warm everything** (OCR, faces, model `prewarm`) when the user turns Level 3 on, not at the first capture: the first-use costs are 6–69 s.

## 3. Schema (for platform)

```swift
@Generable(description: "A short, factual description of one Mac window for a private activity journal")
struct FrameDescription {
    @Guide(description: "The app in front, by name, for example Xcode, Terminal or Safari")
    var app: String
    @Guide(description: "The document, file, web page or conversation the window shows, or empty if none is visible")
    var document: String
    @Guide(description: "One sentence of at most 20 words saying what the person is doing. No names of private people, no numbers, no addresses, no secrets.")
    var activity: String
    @Guide(description: "True if the window visibly shows a password, key, token, card or account number, private messages, health or banking details")
    var visibleSecrets: Bool
}
```

**Instructions:**
- *"You describe one Mac window for a private activity journal. Use only what the text shows. Never repeat names of people, numbers, addresses or secrets."*
- Prompt: `App: <name>\nWindow title: <redacted title>\nText on screen:\n<covered OCR lines>`.
- Use `samplingMode: .greedy`.

This replaces Phase A's draft `ScreenDescription`. The topics and activity enum are dropped, because the sentence carried the meaning in every case.

## 4. Open points

- **Capture cost and memory** of `SCScreenshotManager` for a single window at Retina scale: platform, in an owned-window harness.
- **Face tiles on photo-heavy pages** (2 s) are the biggest single cost. A cheaper alternative is pixellating every non-text picture region larger than 48×48 px, which is stronger and faster. It's a product call: it also blurs diagrams and screenshots of designs.
- **The text-cover rule works on whole OCR lines.** That over-covers (the whole "Card ending 4242 · Contact …" line goes) but is simple and safe. Covering word boxes (`RecognizedText.boundingBox(for:)`) can come later.
