# LM2-D-A verification

Phase D app presentation uses the platform's optional journal access and rule lifecycle seams. All fixtures use private defaults, temporary histories, synthetic records and fake keys. Native checks use owned offscreen windows; no screen capture, global keyboard events, real agent configuration or credentials.

## Repeatable checks

- `scripts/build.sh`
- `scripts/test.sh`
- `scripts/check-public.sh`
- `TEST_RUNNER_LM2D_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination platform=macOS -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages test -only-testing:ZeusTests/LM2DAppTests -only-testing:ZeusTests/LM2DRulesTests -only-testing:ZeusTests/LM2DNativeTests -only-testing:ZeusTests/LM2DRenderTests`

## App-side results before final core adoption

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

Designer approved the native all-theme render set (seven themes, both system appearances, 1×/2×), including consent, switches, ledger words/pictures/refusals, Rules, Why and quiet lines. The pixel outcome marks were separately approved. The expanded ledger item's ISO timestamp is literally the timestamp sent by the runtime. No ZeusDesign source or tests changed. The designer's Phase D copy branch is adopted by original-history merges.

## Environment gate

During the full-suite run, the console locked (`IOConsoleLocked = Yes`). Encrypted journal/rules fixture writes then failed with Cocoa 513 / errno 1 at complete-file-protection writes. The already-failed full app run was interrupted after recording those failures, rather than waiting through further encrypted-fixture timeouts. Protection was not weakened and no test bypass was added. These gates require a subsequent unlocked-console run; focused app fixtures and render results must not be presented as a full-suite pass.
