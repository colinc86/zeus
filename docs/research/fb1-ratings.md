# FB1 ratings verification

## Implementation

`MessageRatingsProviding` is optional; production supplies exactly one encrypted `MessageRatingStore`. Explicit edits persist with an outbox and guarded Undo in one transaction. Undo restores the preceding choice (or removes a newly created rating), survives relaunch, and refuses to overwrite a later mutation. Corrections release one card and have the same guarded Undo semantics.

New say/ask/present cards carry an optional kind and runtime-derived origin. Only a user-input response row makes a reply. Down-kind matches are persisted before publishing the card. Exact normalized keys precede local sentence embeddings; Up/Neutral, replies and just-this-one feedback never create a kind hold. High priority cannot bypass one.

Ratings deliver even with learning capture disabled. The assistant receives each rating change with its delivery ID and `Files: Zeus/preferences.md`; acknowledged receipts retain the exact text in the ledger without another thread notice. The folder and reflection inputs include current preferences. Delete Everything clears ratings, signals, decisions and pending rating deliveries, suppresses late receipts, and cannot recreate the deleted preferences file through a store observer.

Unavailable startup keys preserve state and retry; new unsolicited cards wait while replies remain usable. Corruption throws rather than creating empty preferences. Tests inject fixture keys exclusively.

## Targeted checks

- `scripts/build.sh`: passed; no new compiler warnings. Existing CoreSimulator/destination notices remain.
- Rating and template suites: 15 tests passed. Final rating-only boundary rerun: 11 passed, including erased-file absence and failed-ledger outbox retry.
- `MessageRatingMetadataTests`: 2 passed (legacy card decoding, metadata round trip, schema bounds and no agent-controlled origin/hold).
- `scripts/test_live_gate.py`: 10 passed.
- Full `scripts/test.sh` belongs to PM; not run on this branch.

## Real Claude proof

`FB1LiveProbe.py --record` passed with Claude Code **2.1.301**. Production runtime, managed controller, tmux transport, embedded zeus-mcp and NLEmbedding were used with a private socket, disposable HOME/config, scratch folder, fixture encryption key and localhost synthetic model. The owned processes and namespace were cleaned up.

1. Real Claude posts `about: On-call reminder` unprompted.
2. Runtime rates it Stop for the kind; writes `Zeus/preferences.md`.
3. Claude receives the rating envelope and calls `zeus_ack` (attempt 1).
4. Claude posts `about: Rotation heads-up`, priority high, with a differently worded reminder.
5. Both cards remain in the thread; the new one has the semantic hold before add. Engine `naturalLanguage`, score **0.3911726475**, threshold **0.35**.

Scrubbed evidence: `TestFixtures/live/fb1/ratings.json`. The probe waits for Claude's MCP registration using its native `WaitForMcpServers` tool; the first model request can precede tool registration.

## Similarity calibration and limits

Measured with the installed English NLEmbedding sentence model against:

> On-call reminder / Your on-call shift starts soon. Check the rotation and handover notes before your shift.

| Input label and text | Similarity |
|---|---:|
| Shift handover / same example text | 0.710487 |
| Rotation heads-up / Your on-call rotation is about to start. Review the handover notes before taking over. | 0.391173 |
| Pager duty / You are on call tonight. Review the rotation schedule and handover notes. | 0.230778 |
| Build results / Your requested build passed. | -0.042495 |
| Meeting prep notes / Review the agenda and draft questions before the design review. | 0.021179 |
| Unseen urgent message / A teammate needs your approval to unblock a release. | 0.073279 |
| Lunch reminder / Take a break and have something to eat. | -0.158162 |

Runtime clamps negative scores to zero. The initial uncalibrated 0.80 missed even identical text with a new label; 0.35 separates the proved paraphrase from these unrelated examples. This small synthetic calibration does not establish general precision/recall: the pager-duty example remains a false negative. Every hold records its engine/threshold and supports a per-card correction. If the installed language has no sentence embedding, exact matching still works; no remote model or download is used.

## Final quick gate

`scripts/live.sh --quick` passed **20/20 probe/agent rows**, no skips, in **475.62 s**, on implementation `5969830`. Manifest: `build/live/20261016T173917.491714Z/summary.json`. Includes FB1 and LM4 real Claude, app control/card lifecycle, Claude/Codex/OpenCode activity and turn completion, own-session screens, classifiers, Connect Your Own, and the private-tmux E2E suite. The gate rebuilt the app/test host before running.

The first attempt exposed missing concrete redactor dependencies in older headless host source lists. `LiveSupport.py` and the app-owner-authorized E2E source list now include those dependencies; the complete final gate above passed from the corrected source state. No production behavior was weakened or test deadline changed. `scripts/check-public.sh` and `git diff --check` also pass.
