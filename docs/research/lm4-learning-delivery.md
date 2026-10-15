# LM4-P — learnings reach the assistant

## Behavior and integration

- Digests and moments enter the durable delivery ledger even before a bridge
  connects. They keep their learning ID and exact redacted content, use kind
  `learning`, carry `learning_kind`, and use the normal managed/native transport.
  Proven-dead destinations retarget like compose messages and reflections.
- Notifications are an optional hint to the selected assistant, not evidence of
  model receipt. Ack or successful tool-result consumption creates the Sent row;
  transport completion alone does not. Reflections follow the same rule.
- `LearningDeliveryPresenting` is an optional observable runtime capability in
  Agents. Pending snapshots include digest/moment distinction and path-free
  session labels. Draft, busy, and disconnected hold episodes persist in the
  delivery ledger and appear after ten minutes. Clearing a hold bypasses the
  existing retry delay, subject to normal single-send and attempt-budget guards.
  `olderSetup` is reserved for proven setup-specific holds; staleness alone does
  not block a delivery or invent its failure reason.
- Sent notices use `n_<learning.id>`, retain exact detail, the moment suffix,
  and View. Pending disappearance is not proof of receipt. A real journal receipt
  wins if its subsequent queue-consumption transaction fails.
- Learning cancellation uses the existing scoped draft confirmation even for
  one item. It cannot type over native text or cancel messages queued later.
  Discarded learnings cannot return through polling.
- `ManagedSetupStaleness` describes tools/template version separately from user
  customization. An edited current template is not an obsolete setup. Restart
  uses the applied configuration and existing safe resume path; progress/error
  are available through `ManagedSettingsApplying`.
- Exact shipped template hashes allow automatic refresh of unmodified AGENTS.md
  and CLAUDE.md only. User edits and symlinks are preserved. Explicit replacement
  confirms a folder/file-hash snapshot and rejects a changed snapshot or symlink.
  A live adopted lease retains its original setup evidence until an actual launch.
  No other folder files are touched.

The only Learn store change is optional exact-ID read tracking, backward-decodable
from the existing cumulative cursor. This prevents out-of-order acknowledgments
from consuming unseen earlier notes. No Shared/AppSeams.swift or project changes.
CONTRACT §11 and §13 document the optional seam and delivery rule. The live gate
adds the `lm4` probe; it is included in quick and full plans.

## Evidence

`TestFixtures/live/lm4/digest.json` records a real Claude Code 2.1.300 managed
session launched by production ManagedSessionController/ManagedTmux. The model
endpoint is localhost, the HOME/config/project are disposable, tmux uses a private
socket, and journal encryption uses a fixture key. No user agent config,
credentials, default tmux server, or ~/Zeus Assistant was used.

The digest reached the actual model, which called zeus_ack. It took
one delivery attempt, cleared unread state, and recorded the exact summary with
session label `Claude · Zeus`. The helper removes its owned processes and private
namespace. The probe can be repeated with:

```
python3 -B Zeus/App/Tests/Runtime/LM4LiveProbe.py
scripts/live.sh --only lm4 --quick
```

Initial focused verification passed 51 tests across six suites. The first full
checkpoint ran 1,022 app tests and failed five assertions in one legacy-migration
test: its expected records omitted the newly persisted hold fields. The expected
records now include those fields while preserving full equality checks of target,
content, retry budget and migration behavior. Packages and offline fixtures passed.
Logs: `build/lm4-focused-final.log`, `build/lm4-full.log`, and
`build/lm4-full-summary.json`. Final integrated/full/live results follow below.

Final integrated app/core verification (appdev branch `8552e89`, core `88e6719`):
`scripts/test.sh` passed 1,040 app tests across 213 suites in 510.924 seconds,
249 package tests, and offline gates. The subsequent incremental `scripts/build.sh`
passed with no new compiler warnings. Appdev logs are `build/lm4-full.log` and
`build/lm4-build-final.log` in its worktree. Its native AX/render checks and designer
review also passed. The platform quick live gate is recorded separately below.

## Erasure gap found during integration review (resolved by follow-up)

Delete Everything resets LearningsStore and removes learning notices, but the new
`.learning` records remain in the durable delivery ledger. Pending presentation
can therefore recreate Ready lines and delivery can later send the deleted text.
The existing reflection-evidence reconciliation only covers reflections and
intentionally excludes journaled native pastes. This is not fixed by hiding UI rows.

The required resolution was an explicit runtime erase boundary that cancels queued
learning/reflection deliveries and suppresses late receipts/relaunch replay. PM
chose to leave already-pasted native text alone, without automatic submission. The initial checkpoint did not implement erasure. PM approved the follow-up
below on the same branch.

## Final quick live gate

`scripts/live.sh --quick` passed on core `88e6719` in 421.37 seconds. All 19
probe/agent rows passed, with no skips: LM4, AC1, LV1, SA1, SA2, SA3, SA4, PC1,
CY1, and E2E. This is quick smoke coverage, not a claim that the full live-release
matrix ran. LM4's real-Claude digest/ack probe passed again in 38.49 seconds.
The bounded gate completed normally and its test/build processes exited.

Artifacts: `build/lm4-quick.log`,
`build/live/20261015T213751.586149Z/summary.json`, and the adjacent `summary.md`.
These pre-erasure gates did not establish Delete Everything correctness. The
post-erasure verification below covers the approved follow-up.


## Approved erasure follow-up

Commit `e379999` adds optional synchronous deletion callbacks to JournalStore's
production implementation and LearningsStore. Delete Everything discards all
learning/reflection records; per-item/group deletion discards deliveries whose
learning ID or reflection evidence was removed. Read tracking is explicitly
separate from deletion. App adapters need no changes.

Before a deletion callback returns, the runtime invalidates send tokens, cancels
in-flight tasks, removes pending presentation, and writes discarded tombstones with
empty content. A late connector completion, acknowledgment, tool-read receipt, or
relaunch replay cannot restore a Sent row. Already-pasted native input is left
untouched and is never automatically submitted after erasure, as directed by PM.
New unrelated learnings continue to deliver normally.

Five fake-clock/fake-managed regressions cover queued deletion, evidence deletion
while sending, exhausted native-paste suppression, source reset versus read tracking,
and deletion after acknowledgment across relaunch. The focused learning/Phase D
selection passed 38 tests across four suites. The live digest probe now also erases
the receipt and verifies a late ack does not recreate it. Final post-fix full/live
results follow.


Post-fix `scripts/test.sh` passed on `e379999`: 1,028 app tests across 212 suites
in 431.101 seconds (1,002 passed, 26 expected opt-in skips, zero failures), all
249 package tests, and offline gates. Logs: `build/lm4-erase-full.log` and
`build/lm4-erase-full-summary.json`. Focused result: `build/lm4-erase-focused-final.log`.
Appdev independently adopted the same history at `4bdf9e0`; its final integrated
build, 28 focused UI tests, and five glyph tests passed.

`python3 -B Zeus/App/Tests/Runtime/LM4LiveProbe.py --record` passed again against
real Claude Code 2.1.300. The recorded proof now includes
`erasure_late_ack_suppressed: true`: after the real model acknowledged the digest,
the probe deleted the journal and exercised a late ack/receipt; no Sent row returned.
The digest still took one attempt. This focused live run extends the earlier
19/19 quick gate; the full quick matrix was not repeated after the erase follow-up.
Log: `build/lm4-erase-live.log`; recorded evidence: `TestFixtures/live/lm4/digest.json`.
No probe-owned helpers or test/build processes were left running.

Final `scripts/build.sh` also passed on the post-fix tree, with no new compiler
warnings (`build/lm4-erase-build-final.log`). The erasure merge blocker is resolved.
