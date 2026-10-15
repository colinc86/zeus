# LM2-B evidence

All committed images are generated synthetic pixels. No user window, browser, project, credentials or personal frame was captured.

## Passed

- `synthetic-bank-covered.heic` and `synthetic-bank-boxes.json`: the production `FrameRedactor`, accurate Vision OCR,
  both-stage Redactor interface (native semantic model disabled for this deterministic corpus), solid text covers,
  saliency-based picture pixellation and HEIC encoding. Re-OCR of the HEIC and the deferred-reader path cannot find the
  planted account/routing numbers, card suffix or email. The test first proves those details were readable in the source.
- `synthetic-model-description.json`: actual on-device Foundation Model, designer's `FrameDescription` schema,
  text-only synthetic input. Structured generation and Codable round-trip passed (first call about 7.1 seconds).
- Fake-clock/workspace tests cover dwell, periodic/idle/on-demand triggers, unchanged vs scrolled images, scope/private
  lists, consent, all hard stops, post-await invalidation, permission revocation, deferred descriptions, cap recovery,
  encrypted frames, retention, paired deletion/tombstones/Undo and failed-write preservation.
- Production CoreMediaIO camera listener/state probe returned `cameraHardStop=false` when no camera was running.
  It read device-running properties only, opened no camera and read no video/audio. Active-video refusal is a controlled
  injected-state test, not a claim that a physical video call was performed.

Generate the synthetic evidence (no screen capture):

```sh
TEST_RUNNER_ZEUS_TEST_LM2B_MODEL=1 TEST_RUNNER_ZEUS_TEST_LM2B_EVIDENCE=1 \
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$PWD/build/DerivedData" -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/ScreenLearningTests -only-testing:ZeusTests/ScreenNativeTests test
```

## Incomplete native screen gate

The opt-in native probe was run in a disposable HOME on 2026-10-14. It stopped before creating/capturing a window because
`CGPreflightScreenCaptureAccess()` was false for the worktree dev build. Its explicit failure was:

> LM2-B native gate incomplete: Screen Recording not granted to this dev build; no pixels captured.

Log: `build/lm2b-native.log`. There are no captured images or fabricated success records. Actual Terminal, Xcode and Safari
frame capture, capture latency and physical active-video refusal remain unverified. The existing opt-in test can capture
three fixture-owned simulated app windows after permission is granted; that is an owned-window pipeline proof, not proof
of real Terminal/Xcode/Safari capture.

For an authorized rerun after Screen Recording is granted to the exact dev build:

```sh
mkdir -p "$PWD/build/lm2b-private-home"
HOME="$PWD/build/lm2b-private-home" CFFIXED_USER_HOME="$PWD/build/lm2b-private-home" \
TEST_RUNNER_HOME="$PWD/build/lm2b-private-home" TEST_RUNNER_CFFIXED_USER_HOME="$PWD/build/lm2b-private-home" \
TEST_RUNNER_ZEUS_LM2B_HOME="$PWD/build/lm2b-private-home" TEST_RUNNER_ZEUS_TEST_LM2B_SCREEN=1 \
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$PWD/build/DerivedData" -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/ScreenNativeTests test
```

The normal suite never requests Screen Recording or reads the screen. The opt-in probe never requests permission either;
permission requests belong to the explicit app consent action.

Safari is a separate policy limitation: L2's explicitly allow-listed title/URL exception does not establish that a Safari
window is non-private. Production L3 fails closed for unknown browser privacy, including allow-listed Safari. A positive
normal-window signal must be tied to the exact bundle/PID/CG window identity. The real Safari frame expectation therefore
needs either a verified privacy signal or a new PM-approved policy; the L2 exception is not silently broadened.
