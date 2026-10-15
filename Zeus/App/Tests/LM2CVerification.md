# LM2-C-A verification

All app tests use private defaults, paths and fake keys. Observer tests inject a fake; the retained-data test leaves capture off. Native renders use owned offscreen NSHostingView.cacheDisplay views, not screen capture or Computer Use.

## Repeatable checks

- `scripts/build.sh`
- `scripts/test.sh`
- `ZEUS_TEST_TMUX=1 scripts/e2e.sh`
- `scripts/check-public.sh`
- `TEST_RUNNER_LM2C_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination platform=macOS -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages test -only-testing:ZeusTests/LM2CTypingRenderTests`
- `python3 Zeus/App/Tests/LM2CNativeProbe.py` (after building the app tests)

## Final results

- `scripts/build.sh`: passed with no new compiler warnings (the existing ambiguous-destination notice remains). Log: `build/lm2c-build-gate.log`.
- `scripts/test.sh`: all ZeusKit suites passed; app result: 954 tests in 195 suites, 931 passed, 23 intentionally skipped, zero failures. Log: `build/lm2c-test-gate.log`; result summary: `build/lm2c-test-gate-summary.json`.
- Focused model/viewer/adapter/native-layout and all-theme render run: 21 tests in five suites passed. Log: `build/lm2c-review-final.log`. The final full suite additionally covers filtered group deletion and interrupted-picker recovery.
- `scripts/check-public.sh`: passed. Log: `build/lm2c-public-gate.log`.

## Coverage

- Typing starts off; only an allow list is accepted, and the shared private list wins. Apple Intelligence is required before first consent. Consent cancellation never enables capture or requests permission. First use picks apps before Input Monitoring is requested; picker cancellation leaves the level on with an empty, safe allow list.
- Waiting, denied, revoked, reopen, private-input and model-unavailable presentation; existing permission and later revocation never request again. An interrupted first picker still explains missing permission after relaunch. Pause for Today resumes at its actual deadline independently of Level 1.
- Topics default to 30 days with 7/30/90 choices; words default to 24 hours with none/day/week choices. Shortening prunes immediately, reports a failure honestly, and uses the real store's monotonic expiry and topic ceiling.
- App/hour groups, topic and word search, expired/absent words, IME records, a distinct pasted chip, atomic per-stretch/group deletion and scoped Undo. Group deletion covers the entire named hour even under a text search; its count includes hidden stretches. Long words receive their full multiline height; short consent sheets pin the send disclosure, permission caption and buttons.
- The private-input menu line is disabled and has no action. It creates no card, notice, avatar cue or VoiceOver announcement.

## Renders and ownership

`build/lm2c-renders` has 196 native images: seven themes, both system appearances, 1x/2x; Typing settings, normal/short consent, grouped journal, private input, denied permission and model-off states. The designer gave final look/copy approval, including the Safari consent note and the 14:00 fixture with distinct words per topic. No ZeusDesign code changed. Designer's approved retention and Safari copy (84804af, 47e7be0 on designer/lm2c-copy) is merged with its original history.

Platform core is adopted with original history through 2de500e, including real TypingObserving/TypingJournalStoring, configurable expiry, atomic delete/restore, the owned-editor probe and the stale-grant/revocation fix. App code does not add a second key tap, redactor or summarizer.

## Native live gate

The actual Debug app test host ran with a disposable HOME. Input Monitoring preflight was false, so the probe stopped before creating any tap, window or permission prompt, and no keys were read. `build/lm2c-native/result.json` and `native.log` record the blocked result. The three editor runs (including paste and a native secure field), physical-key capture and live permission revocation remain unverified. Deterministic injected tests and native renders do not replace that acceptance proof.

## Requested contract line

CONTRACT §10.5: while Level 4 is enabled and secure input is active, both Zeus menus show the disabled status line “Private input: Zeus isn't noting typing”. It disappears when secure input ends. It produces no avatar/thread cue or VoiceOver announcement.
