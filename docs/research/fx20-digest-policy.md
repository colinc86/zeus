# FX20 — outbound learning privacy

Morning summaries now use the same app-supplied policy snapshot as reflection and brief builders. Enabled levels, shared private apps (bundle ID or display name), and chosen-app scopes are checked before sampling. Journal-tool answers also apply the per-item policy. The snapshot is local bookkeeping; the agent receives only an opaque fingerprint, never the private-app list.

Unread morning summaries persist their source day and policy fingerprint. A change rebuilds their text from retained records, removes the old learning identity, cancels its queued delivery, and exports the replacement summary. Legacy unread summaries without provenance are rebuilt from the last retained day before their creation; those without a safe source are withheld. An old acknowledgement cannot consume a replacement. Briefs and reflections similarly replace pending snapshots, including when a user returns to a previously used policy. Already-consumed summaries and their historical Sent receipts remain exact.

Activity transitions are retained while excluded names are suppressed: an allowed app at 09:00, a newly private app at 09:10 and idle at 09:30 produce 10 minutes in the allowed app and 20 minutes of private time, rather than attributing all 30 minutes to the allowed app.

## Before / after

Synthetic screen/typing records from an app later made private:

- Before: the newly generated morning summary included `On screen: SCREEN_0` and `Typing: TOPIC_0`.
- After: neither appears; permitted `SCREEN_1` / `TOPIC_1` remain.
- Turning Screen and Typing off removes both pairs from new summaries.
- Narrowing their chosen-app lists gives the same filtered result as the private-list case.
- The exported `summary.md` is checked against the exact rebuilt learning text.

## Boundaries

Policy changes do not recall text already read by an assistant. A cancelled delivery's already-pasted native input is left alone; it is not automatically submitted or re-pasted. Existing retained journal records and historical Sent receipts are not retroactively deleted by a capture-scope change. Explicit deletion and retention continue to control those records.

Cross-owner changes were approved by appdev: LearningPresentation snapshot/notification wiring, Shell runtime injection, and the E2E host's explicit source-list addition. No Settings copy or controls changed. CONTRACT §13 documents the policy and replacement boundary.

## Verification

`DigestPolicyTests` exercises real encrypted fixture storage, LearnFromMe, LearningsStore, runtime ledger, fake transport and the folder writer; keys and folders are injected. `OutboundPolicyTests` exercises real reflection/brief builders and their folder output. The regression matrix covers level-off, private-list, chosen-app, allowed control, post-queue restriction, late ack, repeated policy changes, persisted provenance and unchanged consumed receipts.

Final verification on `50b508f`:

- `scripts/build.sh`: passed, no new compiler warnings; the existing multiple-destination warning remains.
- `scripts/test.sh`: passed, 1,265 app tests in 257 suites (1,226 passed, 39 expected skips), 471.337 seconds. All 277 package tests and offline checks passed.
- `scripts/check-public.sh`: passed.
- Complete `scripts/live.sh --quick`: all 26 rows passed in 613.13 seconds, including Claude, Codex, OpenCode and the private-process E2E suite. The live build began on `1c4ef76`; the final L1-only fingerprint fallback and regression in `50b508f` were subsequently verified by the final build and full suite above.
- Tmux hygiene reported no new shared-directory entries or orphan managed fixture servers.

No assertion or timeout was weakened. All storage keys, folders and agent namespaces were isolated. Task build output was kept under `build/tmp/fx20/` through task-owned aliases and removed before handback. The heavy slot was released to appdev (FX21), then designer (FX19).
