# S1 conversation scroll benchmark

Current S1c runner (Release profiling build):

```sh
xcodegen generate --quiet
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/ReleasePerf" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ZEUS_PERFORMANCE_PROBE' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
scripts/scroll-perf.sh --matrix --captures 5 --label s1c-release
```

Default N is five. For one configuration use `--configuration baseline` (or `opaque-panel`,
`single-frame`, `avatar-paused`, `sf-mono`, `local-events`). `--matrix` interleaves configurations
in each of five rounds with a reproducible seed (default 13). Every launch uses an isolated home
and the same 200 mixed cards, requested 120 callbacks/second and 2,400 points/second round trip.
No global input events or screen capture are used; passive windows cannot become key.

Artifacts are in `build/scroll-perf/batch-<timestamp>-<label>/`: `batch.json`, `batch-summary.json`,
per-capture fixtures/readiness/logs, exported hitches and summaries. The first trace of each
configuration remains; subsequent traces are removed after exporting, to limit disk consumption.
Use `--retain-traces all` to keep every trace. Raw Instruments staging is identified from the
runner's own recorder PID and cleaned only after child exit, with inode checks.

Each configuration reports median and full min/max for hitch ms/s and per-capture worst hitch,
the untrimmed values, valid N and gates passed. An outlier remains in the range. An invalid run
stops the batch and does not count toward N; fix its cause and use `--resume <batch-directory>`.
Resume requires the same app binary SHA-256. Exports and failed attempts remain as evidence.

The target display must be awake/active and the panel actually visible, including occlusion.
Preflight runs before Instruments and health checks continue during scrolling. Ignore-occlusion
controls for animation liveness do **not** override this rendering validity check. The optional
local-input driver first traverses the fixture without recording; it must move the native viewport
through both endpoints and produce an `interacting` phase. If unavailable because of display state,
the batch stops. If unsupported on an awake display, it is explicitly excluded with its pilot result;
there is no global-event fallback.

`xctrace` uses **Animation Hitches**, including Time Profiler; a unique tracing-start notification
gates each scroll. Hitch summaries filter the target PID and sum hitch milliseconds divided by
recorded seconds, following [Apple's hitch-time-ratio definition](https://developer.apple.com/videos/play/tech-talks/10855/).
The recording includes the initial bottom-to-top seek and the round trip, not application startup.
Callback gaps are not rendered hitches. The gate is <5 ms/s and no hitch above 16.667 ms (two
120 Hz frames, with 1 µs timestamp tolerance). A 60 Hz display cannot establish actual 120 Hz behavior.

The sections below preserve S1/S1b's historical measurements. Their native prototype and old
`--thread` / `--opaque-cells` commands exist only in git history; S1c removes that code from the app.

## Measured 12 October 2026

Apple M1 Pro, macOS 27.0 / Instruments 27.0, Debug app, pixel font, animations active.

| Capture | Hitch ms/s | Worst hitch | Hitches | Capture / scroll seconds | Target updates |
|---|---:|---:|---:|---:|---:|
| Before app changes | 380.870 | 6,850.032 ms | 67 | 30.807 / 27.482 | 71 |
| After app changes | 26.496 | 50.000 ms | 37 | 27.048 / 23.765 | 949 |
| Required | <5 | ≤16.667 ms | — | — | — |

Before: `build/scroll-perf/20261012-213639-before-notified/`, benchmark commit `263a7df` over main `a5df6b2`.

After: `build/scroll-perf/20261012-221337-after-passive/`, commit `cbbec7b`.

The final capture stayed visible throughout. The earlier `after-isolated` capture lost its window and is explicitly rejected (`surface_valid: false`). Initial collector failures are excluded. The remaining worst final events are marked render/GPU work; the gate is **failed**. Designer's S2 palette-cache fix (`f587726`) was still unmerged and is not included in these measurements.

## Verification

- `scripts/build.sh`: passed; no new compiler warnings.
- `scripts/test.sh`: 321 app tests passed, two optional skips; all ZeusKit tests passed.
- `ZEUS_TEST_TMUX=1 scripts/e2e.sh`: 26 passed, zero skips.
- Native scroll/seen/pill/peek regressions: 10 cases passed, plus chronology-cache and indexed-layout tests.
- Separate 30-second CPU captures with animations forced active: closed **0.67% → 1.00%**, open with 31 cards **0.73% → 1.00%**. Both remain below the 2%/5% ceilings; these single captures do not establish strictly unchanged CPU. Logs: `build/s1-before-{closed,open}.log`, `build/s1-final-{closed,open}.log`.

## Proposed next step: native thread prototype

Use a single-column, view-based **NSTableView** inside an NSScrollView, bridged by NSViewRepresentable. Keep ConversationModel, the composer, the outer Zeus dialog and existing ZeusDesign bubble content. Reuse NSHostingView cells; cache measured heights by entry content, font and palette, and apply insert/update diffs by stable entry ID. Scrolling then changes native clip bounds without evaluating the whole SwiftUI thread or estimating a long LazyVStack's geometry.

Get visible rows and message positions from the table's native row rectangles. Preserve the newest-bubble top cap (including its divider/session-label inset), 300 ms seen tracking, the new-message pill, history loading, keyboard focus and peek targets. Invalidate only affected cell heights for answers, attachments, typewriter growth and activity progress. Keep the reveal-once model unchanged.

First combine S2 and rerun this harness. If still above the gate, benchmark a small native-thread prototype against the same fixture before migrating interactions. Render/GPU hitches may also come from compositing, so an NSTableView is a hypothesis to measure, not a guaranteed fix. No native-thread rewrite has been started in S1.


## S1b: combined S1/S2 and native prototype (12 October 2026)

Main `b2a480c` includes the designer's S2 palette cache. Measurements use the same fixture,
font, passive window, active avatar, speed and 60 Hz display as S1. The prototype's range is
28,282 points versus SwiftUI's 28,263 (0.07% difference from integral row-height rounding).
Both traversals take about 23.8 seconds. Ratios include the initial bottom-to-top seek,
just as S1 did. These are individual captures, not estimates of run-to-run variance.

| Step | Hitch ms/s | Worst hitch | Hitches | Target updates | Gate |
|---|---:|---:|---:|---:|---|
| S1 app changes, before S2 (previous task) | 26.496 | 50.000 ms | 37 | 949 | Fail |
| Combined S1/S2, Debug | 11.065 | 83.333 ms | 13 | 604 | Fail |
| Combined S1/S2, optimized Release | 50.682 | 133.333 ms | 60 | 1,344 | Fail |
| NSTableView prototype, Debug | 30.044 | 50.000 ms | 39 | 389 | Fail |
| Native with opaque cells, Debug | 22.166 | 33.333 ms | 33 | 240 | Fail |

Artifacts:

- Combined Debug: `build/scroll-perf/20261012-224548-s1b-combined-debug/` (main `b2a480c`).
- Combined Release: `build/scroll-perf/20261012-225136-s1b-combined-release/` (main plus profiling flag).
- Native: `build/scroll-perf/20261012-230343-s1b-native-debug-valid/` (`3242b0d`).
- Opaque native: `build/scroll-perf/20261012-231338-s1b-native-opaque/` (`1475f69`).
- `s1b-native-debug` completed its traversal but ran out of space while saving. Its malformed
  trace is rejected; callback timings and the completed traversal are not rendered-hitch evidence.

The Release run did not improve the measured result. It includes an app-update hitch of
133.333 ms during the initial seek and later render/GPU delays. One run does not establish
that Release is generally slower than Debug. The native prototype does **not** clearly beat
combined SwiftUI, so interaction migration is not justified and has not been performed.
The production thread, focus, newest-top cap, seen tracking, pill, history loading and peek
routing stay on their existing SwiftUI implementation.

The gated prototype is a single-column view-based NSTableView in NSScrollView. It uses the
production row/bubble factory and reusable NSHostingView cells, measures static heights once,
caches by entry/neighbors/font/palette/caption/session label plus width, and applies stable-ID
insert/remove and changed-row updates. It supports the benchmark's initial seek; it is not an
alternative live conversation UI. Only `ZEUS_PERF_THREAD=native` plus an isolated home enables it,
and its code is excluded from ordinary Release builds.

### Compositing evidence and experiment

Hitch narrative categories overlap. Combined Debug records 2 app-update hitches (50.000 ms),
6 render hitches (166.667 ms), 2 GPU hitches (33.333 ms) and 3 unclassified hitches (50.000 ms).
Native records 15 app-update hitches (350.002 ms), 6 render hitches (166.667 ms), 7 GPU hitches
(166.668 ms) and 16 unclassified hitches (283.334 ms). Native therefore adds app work as well as
retaining render/GPU delays; neither capture proves a solely GPU-bound problem.

The native Time Profiler export contains 4,849 ms of main-thread sampled weight. Inclusive
stack classifications contain NSHostingView frames in 3,394 ms, `layout` frames in 2,935 ms,
and ZeusMarkdown frames in 19 ms (these groups overlap). The table cell factory appears in
10 ms and the coordinator update method in 2 ms. This points to deferred hosting/layout work,
not repeated full-thread model rebuilding or markdown parsing, as the prototype's CPU cost.
The classification is a substring analysis of symbolicated stack frames, not exclusive function
self time. Source export: the native artifact's `time-profile.xml`; counts: `profile-summary.json`.

The native backing-layer census at the top of the fixture is 63 layers / 6 clipped or masked
layers, rising to 76 / 7 at the end. No opaque, rasterized or CALayer-shadow layers were found.
This counts native backing layers, not every SwiftUI render node. The expensive-render narratives
report **zero offscreen passes**. The dialog's hard shadow is a filled offset pixel shape, not a
CALayer shadow; the layer census is not evidence that the shadow has no rendering cost.

`--thread native --opaque-cells` fills each complete cell and marks its hosting view opaque.
It preserves the row dimensions and clipping, adds one background layer per visible cell, and
creates 4–5 opaque layers (67–81 total). The ratio is 22.166 ms/s (26% below the transparent
native capture), worst 33.333 ms. It still fails both limits and is worse than combined SwiftUI.
Its categories contain 2 app-update hitches (50.000 ms), 8 render hitches (166.667 ms), 7 GPU hitches
(116.668 ms) and 16 unclassified hitches (266.669 ms); categories overlap. The opaque experiment
therefore retains render/GPU hitches despite making the backing cells opaque. Individual captures
do not establish that all of the measured improvement was caused by the background change.
The subsequent commit's cache-key/diff extensions affect data updates; this immutable fixture
has no data/style updates during its timed traversal.

Designer-owned candidates for a subsequent measured A/B are `ZeusDialogModifier`'s 0.97 panel
fill and `PixelFrame`'s two/three overlapping shape fills. Try an opaque panel and a single drawing
primitive for the pixel frame while preserving the corners, tail and appearance. The current
captures do not demonstrate that either change will meet the gate. Keep the SwiftUI thread while
investigating these costs; the measured native prototype is not a basis for shipping a rewrite.

### Reproducing S1b

```sh
scripts/build.sh
scripts/scroll-perf.sh --label combined-debug
scripts/scroll-perf.sh --thread native --label native-debug
scripts/scroll-perf.sh --thread native --opaque-cells --label native-opaque
python3 -B scripts/scroll-trace-summary-tests.py
python3 -B scripts/scroll-recorder-tests.py
```

For an optimized profiling build (ordinary Release builds do not contain these controls):

```sh
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/ReleasePerf" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ZEUS_PERFORMANCE_PROBE' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
scripts/scroll-perf.sh --label combined-release \
  --app build/ReleasePerf/Build/Products/Release/Zeus.app
```

Record sequentially and run CPU checks separately from builds, tests and Instruments processing.
The harness checks free space before launch, requests worktree-local recorder staging, and also
identifies raw kernel staging files through its own recorder PID's file descriptors (macOS may
ignore TMPDIR). After children exit, it removes only those identified files, checking inode identity;
completed trace/export artifacts remain under build/. Empty traversals cannot pass the gate.


### S1b verification

- `scripts/build.sh`: passed, no new app compiler warnings.
- `scripts/test.sh`: 324 app cases in 49 suites passed (322 passed, 2 optional skips); ZeusKit passed.
- Final targeted prototype test: passed after extending font/palette invalidation and stable-ID
  append/reorder/remove coverage. Existing SwiftUI scroll/seen/pill/peek regressions remain green.
- `ZEUS_TEST_TMUX=1 scripts/e2e.sh`: 26 passed, zero skips.
- `python3 -B scripts/scroll-trace-summary-tests.py`: 5 passed (visibility, traversal, peak and target-update gates).
- `python3 -B scripts/scroll-recorder-tests.py`: passed; verifies ownership filtering and late-opened staging detection.
- Separate 30-second idle CPU, active animations, existing SwiftUI path: **0.50% closed**, **0.63% open
  with 31 cards**, compared with S1's ~1.00% / ~1.00%. These single captures show no observed increase
  and remain below the 2%/5% limits; they do not establish zero variance. Artifacts:
  `build/perf/20261012-232017-s1b-final-closed/`, `build/perf/20261012-232053-s1b-final-open/`.

**Outcome:** no production thread rewrite. Keep the gated prototype for follow-up measurements.
The gate remains unmet, and this 60 Hz display does not establish actual 120 Hz presentation.


## S1c status (13 October 2026)

The N=5 harness, guarded rendering experiments, and native-prototype removal are implemented.
**Measurements are blocked:** both connected displays are inactive/asleep and the login session
is locked. A public CoreGraphics probe reports display IDs 2 and 3: active=0, asleep=1, max=60 Hz.
The existing app windows also report occlusion 8192 (not visible). No S1c rendered median/range
is claimed. The earlier unrecorded wheel pilots recognized `interacting` / `decelerating` but had
zero native and SwiftUI viewport movement while the displays were asleep; they are not measurements.

### Matrix definitions

| Configuration | Change from baseline | Interpretation |
|---|---|---|
| baseline | Combined SwiftUI, pixel font, active avatar, clip scrolling | Release control |
| opaque-panel | `ZeusDialogModifier` panel fill alpha 1; window `isOpaque=true`, alpha 1 and solid palette background | Tests desktop/window blending; the rectangular backing fills transparent corners/tail margins |
| single-frame | PixelFrame paints the identical inset paths/colors/order in one Canvas node | Tests view/layer compositing; not a claim of one GPU draw call |
| avatar-paused | Stops avatar presentation clocks only during the recorded seek/round trip, then restores them | Tests cross-window animation contribution |
| sf-mono | The actual SF Mono font setting | Includes its different sizes/wrapping/document length; not a pure same-metrics glyph comparison |
| local-events | Precise phased CG-backed NSEvents sent only to the fixture window | Tests AppKit/SwiftUI gesture dispatch; not hardware input or global posting |

The designer-owned switches are task-only, compiled under DEBUG or ZEUS_PERFORMANCE_PROBE on
macOS, and also require an isolated home plus ZEUS_PERF_SCROLL. They are off in ordinary Release
builds. The app records window opacity/background alpha, font, avatar activity, input phases,
responsive-scrolling compatibility, native/SwiftUI offsets, display rate and thermal state.
The capture records load average and UTC completion. Local input is prepared but has not yet
been validated on an awake display; the runner will not label a stationary pilot successful.

### Recommendations pending measurements

Do not choose a winning factor from S1b's individual captures. Run the matrix while the display
is awake and the session unlocked, retaining all five results and the ranges. Check each effect
against its baseline in the same round and inspect peak/gate counts, not only median ratios.
No production rendering fix is shipped from these unmeasured hypotheses. An opaque **window**
requires visual review: its backing covers the pixel corners, hard-shadow margins and tail gaps.
The switches remain experiments; the designer owns any final visual implementation.

### Verification

- `scripts/build.sh`: passed; no new app warnings.
- `scripts/test.sh`: 325 app cases passed (323 passed, two optional skips); ZeusKit passed.
- Batch statistics tests: three passed (untrimmed outliers, invalid capture counts, seeded per-round coverage).
- Hitch-summary gate tests: five passed; recorder ownership/late-staging test passed.
- Wheel payload tests: precise deltas/phases/local coordinates, and rejection of detached input.
- Optimized Release profiling build passed; ZeusDesign compile conditions include ZEUS_PERFORMANCE_PROBE.
- `ZEUS_TEST_TMUX=1 scripts/e2e.sh`: 26 passed, zero skips.
- Final matrix preflight rejected the asleep/inactive panel display before launching Instruments:
  `build/scroll-perf/batch-20261013-003702-s1c-release/input-preflight/readiness.json` reports
  `display_awake=false`, `window_visible=false`, `ready=false`. All six configurations have 0/5
  valid captures; medians/ranges are **unavailable**, not zero. Batch metadata and summary remain.

After the displays are awake and the session unlocked, resume the prepared batch without rebuilding:

```sh
scripts/scroll-perf.sh --resume build/scroll-perf/batch-20261013-003702-s1c-release
```

If the Release binary changes, start a new `--matrix --captures 5` batch instead. No profiler or
fixture app is left running by the rejected preflight.
