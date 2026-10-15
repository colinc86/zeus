# LM2-B-A verification

All app fixtures use private defaults, paths and fake keys. The native capture probe has a disposable HOME and refuses to capture any window except its own synthetic window. It never requests Screen Recording or browser automation permission. UI images use NSHostingView.cacheDisplay on owned views; no desktop screenshots or Computer Use.

## Repeatable checks

- `scripts/build.sh`
- `scripts/test.sh`
- `ZEUS_TEST_TMUX=1 scripts/e2e.sh` (private server only)
- `scripts/check-public.sh`
- `TEST_RUNNER_LM2B_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination platform=macOS -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages test -only-testing:ZeusTests/LM2BRenderTests`
- `python3 Zeus/App/Tests/LM2BNativeProbe.py`

## Final results

- `scripts/build.sh`: passed; no new compiler warnings (the existing ambiguous-destination message remains).
- `scripts/test.sh`: passed, including every ZeusKit suite; app result: 913 tests in 189 suites, 891 passed, 22 skipped, zero failures. Log: build/lm2b-test-verified.log. Summary: build/lm2b-review/full-test-summary.json.
- Focused model, native layout/accessibility and all-theme render run: 39 tests in 9 suites passed. Log: build/lm2b-final-focused-and-renders.log.
- `ZEUS_TEST_TMUX=1 scripts/e2e.sh`: passed, 28 tests, zero skipped; private tmux server. Log: build/lm2b-e2e-final.log.
- `scripts/check-public.sh`: passed.

The render opt-in writes `build/lm2b-renders`: seven themes, both system appearances, 1x/2x; Screen, consent, journal, picture detail, Rules, Privacy and actual draft chips. Additional images show the Safari caption indent, a real-shaped private-time record, and the shared private list when Level 1 uses an allow list. The picture fixture covers a complete Vision OCR line with the production cover operation before the encrypted store receives it.

## App regression coverage

- Explicit Screen consent, cancellation, permission request only once, granted/denied/revoked/reopen states, quiet hard-stop copy, independent scope and retention.
- A fake clock and suspended deadline prove Screen resumes when Pause for Today expires, with Level 1 off. Allow-listed Safari is the explicit exception; other unknown browsers remain blocked.
- Paired frame/description timeline rows, filtered-day navigation, retained description after picture deletion, atomic Undo, Delete Both, expiry and private/deleted reasons, metadata-only export.
- Ask About This with L2 only or L3 only, separate redacted context files, current-context revalidation (including switching windows inside one app), changed/private/secure/paused refusal, removable drafts and attachment-only Send. Capture has no messaging dependency.
- Context delivery intent is saved with Send/answer. A queued attempt produces no Sent row. Actual runtime receipts, failed history/journal writes, restart recovery and duplicate receipts are tested. Delete Everything persists an erase boundary so delayed receipts cannot restore old ledger entries.
- A1–A10: fixed appearance, wrapped chips, one shared private list, pane order and global actions, captions, Safari indent, repeated app line, Private label/internal metadata omission, rule trigger wording and meter spacing.

## Live gate limitation

The isolated native host reported Screen Recording unavailable and Safari automation status -1744. It stopped before reading a window or taking a picture. Accessibility was available. A second probe used the actual Debug app test host (ScreenNativeTests, with a disposable HOME); it independently reported Screen Recording not granted to this dev build and captured no pixels. Evidence is in build/lm2b-native/results.json and build/lm2b-review/dev-app-native-result.json. Real Terminal and disposable Safari URL+frame acceptance is therefore outstanding; synthetic renders and injected pipeline tests are not a substitute for that gate. Granting permission belongs to the app's explicit consent flow, not the probe.

Production Safari policy follows the PM decision: it is pictured only when explicitly allow-listed for Level 3, including private windows which Safari cannot identify. Both its row and consent sheet explain this. L2's independent allow-list exception is unchanged.

## Integration and ownership

Platform core history was merged rather than replayed as duplicate commits, including main 1f19d32 (merge 1179d79). All screen features now use the real ScreenSeams and frame journal. The capture cap defaults to 12 per hour.

Designer-approved helpers bfa4278 and thumbnail support 19a6b90 were adopted as exact patches, with the authorized ec4215a actor annotation on the new test. No other design-system files changed. The designer independently confirmed the remaining ZeusDesign/test diff is byte-identical to designer/lm2b-chip-thumbnail, so either code merge order is clean. PM should also merge its PRIVACY.md updates through 7631ad7 and caption commit 6e39313 (after the existing Phase A/review spec). The final native renders have design approval, including the complete covered OCR line, private row, shared list and picture chips.

Platform authorized adding ContextSendIntent.swift to its private host source lists; no app-authored runtime or Shared changes.

## Requested contract line

CONTRACT §10.5: Ask About This appears directly below Talk to Zeus in both menus. Its Shift-plus-Talk key equivalent is shown only when the enabled, valid Talk shortcut does not already contain Shift and secondary registration succeeds. The menu action is always present. It attaches locally redacted context for review; nothing is sent until Send.
