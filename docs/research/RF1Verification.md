# RF1 — local reflection patterns

The runtime now builds a deterministic 28-local-day digest instead of sending a day's raw app switches. Rhythm, estimated focus duration, app categories, adjacent sequences, recurring/new topics, retained feedback and today-versus-usual comparisons share local-day identities with rule validation. Repeated weekdays collapse; only outliers break out. Displayed patterns cite two to four different local days. A final appendix contains at most 20 records from the selected day.

Only enabled levels contribute. Typing contributes topics, never retained words; screen frames and their metadata are excluded. A bounded source hash covers all contributing journal IDs, including uncited contributors, so deletion invalidates queued aggregates and suppresses late receipts. Displayed citations remain separate from this provenance. Card/rating/outcome evidence must be listed in the reflection snapshot and still retained at the same observation date.

The designer's request asks for dated conclusions in both Notes files, then up to three supported rules, then one budgeted preparation for tomorrow or an ack. Template v7 and its immutable hashes are included. The reflection folder export and receipt preserve the exact delivery body.

## Verification

- Focused pre-copy revision: 50 tests / 6 suites passed, covering pattern construction, local midnight/DST, enabled levels, uncited-source deletion, retained feedback validation, exact folder/receipt content, existing learning behavior and shipped-template history.
- Designer approved the rendered digest against §9.1; the final capitalization/category-label nit is applied.
- Final full `scripts/test.sh`: PASS, 1,174 app tests / 238 suites (1,138 passed, 36 expected opt-in skips), 514.718 s; all 274 package tests and offline checks passed. `build/rf1-full.log`, `build/rf1-full-summary.json`.
- `scripts/check-public.sh`: PASS (`build/rf1-public-final.log`).
- Final recorded RF1 probe: PASS, `build/live/20261018T050226.832024Z/rf1/claude/`, 10.98 s. Native notes, accepted cross-day rule, ack and exact receipt all verified.
- Final `scripts/build.sh --for-testing`: PASS as the quick gate's build step; no new compiler warnings. `build/live/20261018T050249.622620Z/build/app/console.log`.
- Complete `scripts/live.sh --quick`: PASS, 25/25 rows, no skips, 499.71 s. Includes RF1, both PA1 probes, existing Claude/Codex/OpenCode probes and private-process E2E. `build/rf1-quick.log`, `build/live/20261018T050249.622620Z/`.
- Private fixture cleanup completed; tmux hygiene reported no new shared-directory entries. `build/tmp/` was deleted before handback. Logs and scrubbed proof remain.

An initial full run was stopped only because the final copy tweak landed just after its compiler read the builder. The reported green run rebuilt the final source; its object timestamp was checked. No test deadlines, expectations outside the obsolete reflection-format assertions, or production transport safety checks were weakened.

## Real CLI proof

`rf1` is registered in `scripts/live.sh`, including `--quick`. It seeds a two-week synthetic routine, uses an injected fixture encryption key, launches real Claude Code 2.1.302 in a private tmux socket with a disposable HOME/config and a localhost model, and verifies:

1. Production runtime reflection reaches the real CLI through the production tmux connector.
2. Native `Write` creates dated `Notes/about-you.md` and `Notes/patterns.md` in the scratch project.
3. `zeus_get_rules` and `zeus_propose_rules` run through the real bridge; two evidence IDs parsed from the received digest yield an accepted rule.
4. `zeus_ack` consumes the reflection after one transport attempt, and the receipt contains the exact sent text.

The localhost model scripts tool decisions. This proves CLI/tool integration, not an external model's reasoning quality or likelihood of following the prompt. Scrubbed durable evidence is `TestFixtures/live/rf1/reflection.json`.

The private pane is 220×120 so the existing complete-paste verifier can inspect a multi-kilobyte envelope. A 120×40 attempt correctly remained queued with the existing “too long to check” reason; no unsafe paste was forced. Smaller panes still require the existing polling consumption path or more pane space. RF1 does not change connector readiness or paste safety rules.

The first probe failures were fixture setup errors: resizing after launch did not resize the detached CLI's input layout, and the scripted proposal initially used `app` instead of the published `apps` field. Starting the larger pane before launch and correcting the fixture schema resolved them; production transport checks were unchanged.
