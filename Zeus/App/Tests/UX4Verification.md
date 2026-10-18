# UX4 — honest learning lines and a read-only text viewer

Branch: `appdev/ux4-learning-lines`.

## Behavior

- Runtime exposes expired/superseded brief and reflection requests for seven days, with exact retained text, original preparation date and durable reason. Received, explicitly cancelled and erased items are excluded. A failed erasure write also hides the retained text immediately for the running process.
- The app reconciles the existing `n_<id>` line in place. A removed line stays removed. A real receipt wins over pending/discarded presentation; disappearance alone never implies receipt.
- The Sent ledger groups Waiting, Not sent, then Received. Not sent rows expand exact text, and do not affect the received-only export. Empty captions are suppressed when any visible group has rows.
- Shared nouns: Morning summary, Evening reflection, Morning brief request, Note, Rule trigger, Message preference. Message preference deliveries remain ledger-only, preserving FB1.
- Long learning View uses an in-memory, read-only text page. No plaintext file, filesystem watcher, external Open/Reveal, or draft file attachment is created. Its menu is Copy Text / Find. Short notes remain inline. Back restores the thread position and draft.

## Ownership and review

- Platform authorized the narrow Agents/Bridge/Learn changes and Runtime tests, including optional kind metadata, the explicit-erasure guard and ledger-only rating presentation. Core review found no blocker.
- Designer authorized `ZeusViewerHeaderModel.canOpen` (default true), omission of Open for snapshots, and its ZeusDesign regression. No other design-system file changed.
- Vocabulary spec adopted from designer `65f8c3f` as `510cb46`.
- Designer approved the corrected 12 synthetic renders: day-two thread, ledger and long viewer, light/dark, pixel/system. Not sent uses chevron-only disclosure; snapshot pages omit the file-origin row.

## Focused evidence

- 35 model/runtime/viewer tests passed in the initial focused run.
- All existing document return paths passed in the native matrix. The new native test was corrected to enable native accessibility and scroll its fixture notice into view before pressing View; its final run passed with exact Back scroll restoration, Find/Escape behavior, unchanged draft and no attachment.
- Erasure-write-failure, app-attached supersession/expiry evidence and rating pending/ack ledger-only regressions passed.
- Corrected render + native View run: 2 tests passed.
- `scripts/check-public.sh` passed.

## Final verification

- Initial full checkpoint found one obsolete expiry fixture (four assertions): it expected a generic caption and a direct runtime notice. The corrected test attaches the real app presentation and retains all retry, discard, late-ack and no-receipt assertions. All six DeliveryPointerTests then passed.
- Final `scripts/test.sh`: PASS, 1,225 app tests across 248 suites (1,187 passed, 38 expected skips, zero failures), 462.718 seconds; 275 package tests plus offline checks passed. Console-locked active-keyboard tests remain skipped.
- `scripts/live.sh --quick`: PASS, 25/25 rows, no skips, 557.41 seconds. Includes real Claude/Codex/OpenCode probes and private-tmux E2E. No shared tmux entries or orphan fixture servers were left.
- Final build through the live gate passed with no compiler warnings in its incremental log; no new warnings were introduced. `scripts/check-public.sh` and `git diff --check` passed.
- Approved renders: `build/ux4-renders/` (12 PNGs). Retained logs and result summaries: `build/ux4-evidence/`, including the initial failed checkpoint and the final passing runs.
- Task scratch output and its six temporary build aliases were removed before handback. No heavy appdev process remains.

Merge the runtime seam and app reconciliation commits together. UX5 owns the adjacent ledger empty-state copy and brief-enabled closure; retain those when merging its branch.
