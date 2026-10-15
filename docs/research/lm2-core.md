# LM2-P: Phase A core

The integration protocols are in `Zeus/Learn/Seams.swift`. App-owned capture and Settings inject the concrete services;
existing runtime/test constructors remain inert by default. No Shared seam or project-file change is needed here.

## Composition

- `LocalRedactor()`: patterns and NSDataDetector, NLTagger personal names, then the shared on-device Foundation Models
  actor. It sees only first-pass output; its exact-substring spans can only add replacements. One payload's fields share
  one model request. No cloud model, raw-text log, removed-text report, or image input. Input over 128 KB is elided;
  semantic requests over 9 KB, unavailable/busy models, guardrail refusals, errors and eight-second timeouts retain the
  mandatory first pass. The lease remains held until a timed-out native request really exits. This is risk reduction,
  not a guarantee that every private fact is detected. The native model can decline even while availability is available.
- `EncryptedJournalStore(root:keyProvider:calendar:)`: production defaults to `ZeusPaths.appSupport/Journal`, per-day
  AES-GCM, logical file-name authentication, 0700 directory, 0600 ciphertext. Keychain service `Zeus Journal`, account
  `journal-v1`; tests inject `JournalKeyProviding` and never call Keychain. The description/typed-text index exists only
  in memory. Query date bounds are inclusive `from`, exclusive `to`, ascending time then ID, bounded by `limit`.
  Appends are idempotent only for identical items. Deleted items can be appended intact for Undo. Frames are rejected
  until Phase B supplies an image-redaction API. Defaults: activity/focus/descriptions 90 days, typed text 30, reserved
  frames 7. Sent receipts are erased only by Delete Everything, which works even with corrupt ciphertext/unavailable key.
- `try PersistentRulesStore(fileURL:keyProvider:)`: separate encrypted rule state/key account `rules-v1`; mutation commits
  before publishing. Balanced (0.5) is default. Ask me first (0) proposes all agent rules; Balanced activates passive rules
  and shadows acts; Just do it (1) still persists one first-shadow result before activation. Explicit first approval cannot
  bypass shadow. User-created rules are passive, author user, confidence .75. Edits preserve confidence/evidence. Toggle,
  Skip, Undo, accepted and ignored outcomes adjust confidence; below .2 retires. Stable event IDs deduplicate recovered
  outcomes. Rule groups, shown shadows, card associations and consent survive restart. Undo delete restores the exact rule.

`LearnFromMe(..., journal:, redactor:, captureAllowed:)` writes activity through redaction into the same journal; it cannot
append a raw event to the journal backend. It reconstructs L1 summaries from redacted activity. Legacy JSON-lines migration
has stable IDs, deletes each source file only after processing, pauses at hard stops, and resumes on enabled 30-second
recorder ticks. It does not block new captures. Excluded history is not imported. Call `invalidatePendingCapture()` before
policy/context/deletion boundaries; when still enabled, `captureCurrentActivity()` takes a fresh current-app observation
rather than replaying invalidated data. App policy owns private-list/coin, lock and secure-input checks and journal retention.

## Runtime

`ZeusRuntime(..., rules:, journal:, redactor:, learningContext:, reflectionEnabled:, learningCalendar:)` implements optional
`LearningRuntimeControlling`. Defaults do nothing. `reflectionEnabled` must be explicit L1 or L2 consent, never just store
availability. Context supplies the permitted frontmost bundle ID, explicit state facts, lock/private flags, and the actual
last-input timestamp as `idleSince`, even before ten minutes; context changes must call `learningContextDidChange()`.

Reflection runs at the first ten-minute idle after 18:00, or catches up the most recent earlier recorded day on launch. No connected
assistant means no checkpoint/send. A durable `d_reflection_YYYYMMDD` delivery, wire kind `reflection`, uses the normal
connector/ack/retry path. It contains a bounded redacted L1/L2 summary and real evidence IDs and asks for at most two rules.
It never creates a fake user bubble. The ledger enforces at most one reflection per local send day and per summarized day across relaunch. Deleted evidence cancels
unmutated pending reflection, removes the retained reflection body, and keeps the daily tombstone. An already journaled
tmux paste retains its recovery payload until submitted once, then removes that body without recreating a deleted receipt. A stale async preparation cannot
restore deleted evidence or send after capture consent is disabled.

`zeus_get_rules` returns active/shadow plus autonomy; `zeus_propose_rules` validates bounded proposals and retained evidence,
redacts sentences, revalidates session/evidence after suspension, and cannot enable capture or execute external acts.
Trigger dimensions combine with AND, weekdays are Calendar 1...7, wrapping windows belong to their start weekday.
Unconstrained rules guide the assistant and receive outcome feedback, but never hold notifications. Card feedback applies
to the active rules in scope when the card arrived; this is contextual feedback, not a claim of causal attribution.
While L1 or L2 is explicitly enabled, synchronous rule-outcome hooks append generated feedback categories (no question text)
to the journal, including user toggles/edits, so reflection includes outcomes. Existing feedback is not replayed after deletion.

The cards object optionally conforms to `LearningNoticeRecording`:
- Reconnect/update the same notice ID without a new badge, peek or sound; changed nil actions clear stale actions.
- One persisted proposal group gets `N new rules · Review`; `onReviewRule` opens the list/focuses the first rule.
- An act's first shadow result gets `I'd have acted on “…” · OK next time?`. Approval, including from Settings, replaces that same
  line with `OK. I'll do that from now on. · Undo`. Undo atomically restores shadow status and records its confidence signal.
  Not This becomes `Got it. I won't.` with no action; retired acts show `Retired: “…” · Review`.

A matching active passive trigger sets `learningInterruptionHold` before synchronous card arrival. App presentation keeps
badges but holds nonurgent peek/sound; high priority bypasses. `onLearningHoldCleared(ids)` lets app replay the newest
still-unread card under normal visibility/quiet-hours rules. It does not delay user messages to the agent or hide the thread.

The journal's `sentToAssistant` rows are actual successful reflection connector/ack receipts, L1 notification writes or
written `zeus_get_learnings` results, never summary creation or attempted writes. Text is the exact outgoing redacted content;
metadata includes kind reflection/digest/moment, agent, path-free sessionLabel and a SHA-256 sessionID (not a raw cwd).
Legacy L1 summary/note text is redacted on send; the sent ledger is authoritative for the exact sent text, which can differ
from a pre-migration summary's old local View text. Repeated notification/poll consumption deduplicates per learning/session.
No Phase B frame or Phase C typed-text send kind is implemented in Phase A.

## Evidence and gates

- `LearningStoreTests`, `LearningActivityAdapterTests`, `LocalRedactorTests`, `LearningRuntimeTests` cover encryption,
  corruption without overwrite, deletion/restore/export/retention, synthetic precision/recall and exact masking boundaries,
  additive semantics, late capture invalidation, migration, dial/consent/outcome dedup, quiet notice approval/Undo,
  hold release/high bypass, written-only exact receipts and once/day/deletion reflection lifecycle.
- `python3 -B Zeus/App/Tests/Runtime/LM2LiveProbe.py`: real Claude Code, private tmux/HOME/config, localhost fake model,
  production runtime/connectors/bridge/stores and synthetic encryption key. Scrubbed proof is
  `TestFixtures/live/lm2/reflection.json`: reflection at attempt 1, get_rules → propose_rules → ack → say, active/shadow pair.
- `scripts/build.sh`, `scripts/test.sh`, `scripts/check-public.sh` are the required gates; outputs stay under this worktree's build/.

## Contract promotion requested

PM promotes the local protocols and rules tools into §13; add reflection to delivery kinds (§5). In §7/§10, state that an
active evaluable passive rule holds only nonurgent notifications (badge remains, thread remains visible), high bypasses,
and trigger clear replays only the latest still-unread eligible card with existing visibility/quiet checks. Capture opt-in
and app authority boundaries remain explicit; the dial is not a permissions bypass. Sent ledger records writes/consumption,
not attempts, and contains exact redacted outgoing text with path-free recipient identity.
