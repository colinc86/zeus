# LM2-D-A verification

Phase D app presentation uses the platform's optional journal access and rule lifecycle seams. All fixtures use private defaults, temporary histories, synthetic records and fake keys. Native checks use owned offscreen windows; no screen capture, global keyboard events, real agent configuration or credentials.

## Repeatable checks

- `scripts/build.sh`
- `scripts/test.sh`
- `scripts/check-public.sh`
- `TEST_RUNNER_LM2D_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination platform=macOS -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages test -only-testing:ZeusTests/LM2DAppTests -only-testing:ZeusTests/LM2DRulesTests -only-testing:ZeusTests/LM2DNativeTests -only-testing:ZeusTests/LM2DRenderTests`

## Integrated result

- Adopted platform core `121b3bd` by an original-history merge and connected `LearningCardReadState` to durable `CardStore.seenIDs`.
- Combined `scripts/build.sh` passed (`build/lm2d-integrated-build.log`). No new warnings; the existing Sendable callback warnings in Privacy/Character/Appearance and unused binding in ManagedTerminal are unchanged.
- Combined focused run: **15 tests in five suites passed**, including the app models, native actions, all-theme renders and platform's pure Phase D transition tests (`build/lm2d-integrated-focused.log`).
- A subsequent native navigation regression verified an older answer, forty rows down, is actually expanded and visible. **All four native tests passed** (`build/lm2d-navigation-native.log`). This adds one new passing test to the combined set; the other three overlap.
- Combined package suites passed (`build/lm2d-integrated-packages.log`).
- Full `scripts/test.sh` is **not green**: its pre-core full app attempt hit the locked-console protection gate below and was interrupted. That earlier protection issue is resolved for synthetic fixtures by the platform recovery addendum below. The current full-suite blocker is dispatch-worker saturation, not protected storage.

## Earlier app-side checks

- Focused app, Rules, native action and render suites: **12 tests in four suites passed** (`build/lm2d-native-focused.log`). Native thumbnail activation opened an attached picture-detail sheet; the test inspected its accessible title.
- Native renders: **224 PNGs**, seven themes × two system appearances × two scales × eight surfaces, under `build/lm2d-renders`. Designer approved the corrected set and pixel glyph mapping.
- Package suites passed, including the pixel-font audit, in `build/lm2d-test-pre-core.log`. The full app run is blocked as described below.
- Public-file check passed (`build/lm2d-public.log`).

## Coverage

- Raw access defaults off independently for pictures and words. Opening/cancelling the consent sheet does not grant access; Allow persists the grant. Revocation is immediate. Capture must also remain enabled and consented. Levels 1/2 cannot gain raw access.
- Sent answers retain the exact returned JSON. The viewer opens the requested durable answer ID, clearing stale filters and selecting its day. Refused raw access and included words/pictures are distinguished. Covered image bytes are decoded only in an explicitly expanded answer, and its thumbnail opens those same stored bytes in a detail sheet.
- Learning lines reuse the existing ST1 second-action mechanism, never create cards or unread counts, and retain both actions after failed history writes. View/Review remain reusable. Rule context is a hover label rather than inline sent content.
- Why shows only the selected rule's outcomes, newest first, limited to ten plus an earlier count. Category and source are plain text; no numeric deltas or invented previous confidence. Spend rows show Always asks instead of a meter. Decline and dial behavior delegate to the real core.
- Review navigation handles initial and repeated selection, including retired rows. Rule outcome glyphs use existing ZeusGlyph symbols and drawn marks, with text carrying the accessibility meaning.

## Design review

Designer approved the native all-theme render set (seven themes, both system appearances, 1×/2×), including consent, switches, ledger words/pictures/refusals, Rules, Why and quiet lines. The pixel outcome marks were separately approved, including the final dash alignment. Adopted designer/lm2d-copy `9283a86` by original history. The expanded ledger item's ISO timestamp is literally the timestamp sent by the runtime. No ZeusDesign source or tests changed. The designer's Phase D copy branch is adopted by original-history merges.

## Earlier environment gate

During the full-suite run, the console locked (`IOConsoleLocked = Yes`). Encrypted journal/rules fixture writes then failed with Cocoa 513 / errno 1 at complete-file-protection writes. The already-failed full app run was interrupted after recording those failures, rather than waiting through further encrypted-fixture timeouts. Protection was not weakened and no test bypass was added. This recorded the earlier blocker. Platform subsequently isolated fixture-only OS protection and added real storage recovery; see the addendum below for the new integrated gate.

## Storage recovery addendum

- Merged platform recovery `037d10e` by original history. Its explicitly marked fixture key providers opt out of OS file protection only; AES-GCM and atomic file writes remain exercised. Production protection stays intact, and no test uses real Keychain credentials.
- Privacy shows distinct store errors below its status caption, deduplicates identical journal/rules warnings, and supplies the approved memory-only warning when a recovery capability reports unavailable storage or pending writes. Generic store errors remain intact. Adopted designer copy `ade2d4c`.
- Unlock, session activation and app activation call the optional recovery capability only for pending/unavailable stores. The viewer reloads after an attempted recovery. Healthy stores are not retried, and capture consent/policy is unchanged.
- Three fake-store regressions cover capture-off visibility, deduplication, missing-error fallback, both stores, failed recovery and successful clearing. A native accessibility test verifies the complete warning fits the Privacy width. Warning renders cover all seven themes, both appearances and both scales.
- `scripts/build.sh` passed with no new warnings (`build/lm2d-recovery-final-build.log`). The first integrated focused run passed **18 tests in five suites** (`build/lm2d-recovery-focused.log`); it preceded the final wording-only adjustment. Public check passed (`build/lm2d-recovery-public.log`).

### Final gate limitation

Two full runs were attempted after recovery adoption. `build/lm2d-recovery-full-test.log` included opt-in renders and initially overlapped platform's suite. `build/lm2d-recovery-standard-test.log` ran ordinary `scripts/test.sh`, without renders and without an overlapping heavy platform run. Both passed all package suites, then reported managed fixture `.deadline` cascades (Round5ManagedBlockEnd, Round5ManagedDialog/Presentation, SA2Activity). Neither reported protected-storage failures.

Both already-failed app runs were stopped after sampling. Samples are `build/lm2d-full-test-sample.txt` and `build/lm2d-standard-test-sample.txt`. Both reached the dispatch soft limit of 64 workers; the first includes synchronous Vision OCR and the second many blocked `NSAnimation._runBlocking` workers while the main thread pumps XCTest/AppKit. Platform is addressing the separate synchronous OCR fixture call. The remaining native-animation saturation under the locked console is unproven; do not claim a passing full gate or attribute it solely to concurrent runs. Only this worktree's exact test/xcodebuild PIDs were stopped.

Designer approved the storage-warning renders. Their small fixture uses `settingsHeading` for context; the real Privacy pane retains `settingsTitle` and places the warning after its optional model status caption. No ZeusDesign changes.

Final isolated focused verification after the approved wording: **18 tests in five suites passed**, including all nine render surfaces (**252 PNGs**) (`build/lm2d-recovery-final-focused.log`). No test process remains from this appdev verification.
