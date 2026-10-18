# FX8: preserve generated folder facts

## Changes and trust boundaries

- Stored `Learning.text` now goes verbatim to `summary.md` and `moments.md`; the runtime also no longer re-redacts this generated text before delivery. App names, timing calculations and already-redacted screen/typing summaries keep their original facts.
- A manifest-owned old summary/moment file is rewritten on the next refresh from retained learning history. A scratch-folder restart regression seeds corrupted files through the real manifest and verifies exact healed bytes. Unowned collisions and Finder-deleted files keep FX5 semantics. Already-corrupted source text cannot be reconstructed; this fixes the folder copy when the original learning is retained.
- The name tagger rejects spans consisting only of digits, clock times/ranges, durations, weekday or month names. Secret, email, phone, address and financial-pattern detection remain intact. Synthetic names, emails and explicit passwords still redact.
- RF1's pattern digest already formats safe journal inputs without another redaction. Reflection feedback now redacts only user-authored rule sentences before formatting outcome labels, local dates and evidence IDs. Reflections export their exact prepared body.
- PA1's morning brief already formats generated dates and bounded safe journal samples without another redaction; unchanged and regression-tested.
- Rules may be written by a user, so folder export still redacts their sentences. Preferences examples are redacted at rating creation and are exported without another pass. Window titles, typing and screen-description capture redaction are unchanged.
- Universal Control, loginwindow and ScreenSaverEngine are excluded from first/top apps, using known bundle IDs and name fallback. Universal Control retains its time inside the active span, under `On another device`. Excluded/private apps retain privacy precedence.

## Before / after strings

The first two before strings are PM-provided dogfood evidence, not reads of the user's folder. Tests use synthetic learnings and disposable folders with injected keys.

| Path | Before | After / tested expectation |
|---|---|---|
| Folder summary | `Active ‹name›, about ‹name› at the Mac.` | `Active 08:41–23:19, about 14 h 32 min at the Mac.` |
| Folder moment | `First activity today at ‹secret›.` | `First activity today at 08:05.` |
| First-app fact | `First app: Warp at ‹name›.` | `First app: Warp at 08:46.` |
| Fixture top apps | Universal Control would occupy `Top apps` and `First app` | `Top apps: Warp 1 h 23 min.` plus `On another device: 4 h 29 min`; active span unchanged |
| RF1 digest/export | `about 09:00`, `about 5 min` | Same strings; entire exported digest equals prepared text |
| PA1 safe journal sample | `Review at 08:41 for 17 min with ‹name›.` | Same string inside the brief, with `Wednesday 14 October` intact |
| Rules export input | `At 08:41 allow 17 min for mail to alex@example.test.` | `08:41` and `17 min` retained; email absent |
| Preferences example input | `At 08:41, review for 17 min with alex@example.test.` | Redacted example exported exactly; `08:41` and `17 min` retained; email absent |
| Reflection feedback | Redaction of the complete generated feedback block | Sentence-only redaction; local outcome date and suppression until-date retained |

`FolderFactsTests` covers each boundary. A deliberately destructive fake redactor proves the trusted learning, brief and reflection-body paths do not invoke it; a real pattern/name redactor verifies the raw-rule/example boundary. Existing `LocalRedactorTests`, `ReflectionPatternTests`, `LearningSummarizerTests` and `PA1ProactiveTests` also run.

## Verification

- Build-for-testing succeeds; no warnings in changed files. Existing warnings in `ManagedTerminal.swift` and `AppearanceSettingsView.swift`, plus the ambiguous-destination warning, remain unchanged.
- Focused gate: 28 tests, zero failures/skips, including the real pattern/name redactor and folder restart tests. The additional reflection-feedback integration regression passed in the subsequent full run.
- Full `scripts/test.sh`: **1,188 app tests / 240 suites**, 559.314 s, **1,152 passed / 36 expected skips / zero failures**. **274 package tests**, release/live offline tests and tmux hygiene also pass.
- Public check and `git diff --check` pass.
- Full `scripts/live.sh --quick`: **25/25 scenarios**, 518.33 s, including **28/28 E2E tests, zero skips**. LV1's pinned learning expectation passed unchanged. Real Claude, Codex and OpenCode probes passed; hygiene found no new shared-socket entries or orphan fixture servers. Run ID: `20261018T074604.926773Z`.

Universal Control accounting changes newly generated digests. Retained historical learnings remain verbatim, including any old top-app classification; this does not rewrite a body the assistant already received.

All compiler output is routed through the normal script paths into `build/tmp/fx8/`; private live hosts use `build/tmp/live-gate/`. No user folder, default tmux server, credentials or keychain is used. After successful gates, all proof processes exited and `build/tmp/` plus the temporary script-path links were removed before handback, as requested. Gate counts and before/after evidence are retained here; diagnostic binaries and logs were deleted.
