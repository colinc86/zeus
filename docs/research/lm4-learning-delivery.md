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

The digest reached the actual model, which called zeus_ack and zeus_say. It took
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

## Merge blocker found during integration review

Delete Everything resets LearningsStore and removes learning notices, but the new
`.learning` records remain in the durable delivery ledger. Pending presentation
can therefore recreate Ready lines and delivery can later send the deleted text.
The existing reflection-evidence reconciliation only covers reflections and
intentionally excludes journaled native pastes. This is not fixed by hiding UI rows.

Before merge, an explicit runtime erase boundary must cancel queued learning and
reflection deliveries and suppress late receipts/relaunch replay that could restore
erased journal rows. Already-pasted native content needs deliberate safe handling:
neither submit erased content nor discard ownership metadata and classify Zeus's
paste as a human draft. No erase implementation is included in this checkpoint;
the issue was reported to PM and appdev as a merge blocker.

## Final quick live gate

`scripts/live.sh --quick` passed on core `88e6719` in 421.37 seconds. All 19
probe/agent rows passed, with no skips: LM4, AC1, LV1, SA1, SA2, SA3, SA4, PC1,
CY1, and E2E. This is quick smoke coverage, not a claim that the full live-release
matrix ran. LM4's real-Claude digest/ack probe passed again in 38.49 seconds.
The bounded gate completed normally and its test/build processes exited.

Artifacts: `build/lm4-quick.log`,
`build/live/20261015T213751.586149Z/summary.json`, and the adjacent `summary.md`.
Despite green gates, the erase boundary above remains a merge blocker; these gates
do not establish Delete Everything correctness for durable learning deliveries.
