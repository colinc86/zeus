# LM2 Phase D core

## API and integration

`LearningJournalAccessControlling` installs an app-owned `journalAccessPolicy` closure and
`onViewJournalAnswer(answerID)` callback. The default denies all levels. Raw policy is independently
intersected with enabled levels; raw is supported only for screen pictures and retained typing words.
`LearningCardReadState.learningCardWasRead(id:)` is optional: absence means unknown, never unread.
Appdev implements it from durable `seenIDs`. `LearningNoticeRecording` has a source-compatible
secondary-action overload; appdev supplies the ST1 adapter.

Journal answers accept query, ISO date range, kinds, raw and limit; default last day/20 records,
maximum seven days/50 records/20 calls an hour. Answer item JSON is bounded to 400 KB, including
pictures converted from already-covered stored frames to JPEG (640-pixel maximum, 150 KB each).
MCP includes corresponding image content blocks without changing the exact text answer.
Search never uses retained words unless raw typing access was authorized for this request.
Policy and session admission are checked after async query redaction; result construction is synchronous.

The `.sentToAssistant` ledger ID equals `answer_id`. Its payload text is the exact `ToolResult.text`,
not a reconstruction. Details: `kind=journal_answer`, `answer_id`, redacted `query`, ISO `from`/`to`,
`range`, `item_count`, `raw_requested`, `raw_screen`/`raw_typing` (`not requested`, `not allowed`,
`allowed`), `pictures`, `includes_words`, `agent`, path-free `sessionLabel`, SHA-256 `sessionID`.
Receipt creation waits for the bridge's actual written-result receipt. Failed attempts do not fabricate
sent entries. Source deletion before that receipt prevents reinsertion. View callbacks reconnect on launch.
Failed receipt persistence retries in memory; an app crash before persistence can lose that receipt.

Rules persist actions, outcomes, last matches and suppression fingerprints with backward-compatible
optional fields. Agent proposals are bounded to three per day and confidence 0.4–0.7. Evaluable and
spend rules require evidence from two days of an actual recent reflection for that session.
Off/deleted/retired fingerprints suppress re-proposal for 30 days. Fingerprints normalize words and
trigger ordering, not arbitrary semantic paraphrases; agent instructions also forbid rewording refusals.

`zeus_rule_shadow` takes `ruleID`, `wouldHave`; spend additionally requires positive `amount` and
three-letter `currency`. A purchase creates a normal durable high-priority question; every purchase
asks, regardless of amount thresholds. `zeus_rule_acted` takes `ruleID`, `did`, optional `undo`;
spend requires a fresh single-use approval ID for this exact text/session. Spend rules remain shadow.
The runtime records reported actions; it does not execute purchases itself. Undo inserts an idempotent
durable instruction delivery addressed to the original agent session. Decline retires a rule.

Outcomes record dated source and delta. Explicit OK +0.10; acted unchanged 24h +0.03; held read
+0.02 (once/day); action Undo −0.30; early hold Show −0.10; shadow No −0.20; timed skip −0.10;
ignored −0.05; off −0.30; on +0.10; edit raises to at least 0.60 and makes author user; stale
−0.10 per 30 days without trigger match. User-authored rules never auto-retire; others retire below
0.20, with rounded arithmetic at the threshold. Re-enabling retired rules starts at 0.50.
Reflection v2 includes bounded summary/topic samples, outcomes since the prior reflection and
suppression fingerprints. No retained typing words or frame bytes enter reflection.

## Locked storage and test isolation

All audited journal/rules fixtures already injected test keys. The locked-console Cocoa 513/errno 1
failure came from `.completeFileProtection` atomic writes, not reading the user's Keychain.
`FixtureLearningKeyProviding` explicitly selects unprotected **fixture ciphertext**; AES-GCM,
authentication, atomic replacement and 0600 permissions still run. Production defaults retain
protected files and `WhenUnlockedThisDeviceOnly` Keychain accessibility. Keychain requests prohibit
interactive authentication. No test invokes the real provider's `key()`.

`LearningStorageRecovering` exposes `storageWaitingForUnlock`, `pendingStorageWrites`, and
`retryPendingWrites()`. Unavailable storage queues journal entries/covered frames only in memory
(maximum 100 entries, 24 MB frame bytes); repeated IDs are idempotent, conflicting IDs fail.
Deletion removes queued records too. Typing deadlines are frozen when queued and cannot be extended by later preferences; retry removes expired topics and forgotten words before attempting disk access. Full queues report failure rather than silently discard.
Loaded rule changes retain a latest in-memory snapshot; outcome notifications occur once after
successful persistence. Rule tools refuse actions while storage waits. On a locked launch with an
existing unreadable rules file, the store initializes unavailable, exposes no guessed rules and
rejects edits until loading succeeds: it never overwrites unknown state. Corruption is not treated
as temporary lock/unavailability. Queued memory can be lost on quit; the warning says so.

Core retries every three seconds only while unavailable. Appdev wires Privacy status independently
of enabled capture switches, plus immediate retry on unlock/session activation/app activation.
Appdev implements this in recovery commit `0d9ea66`. These app-side changes are a separate owner commit; no production UI files changed here.

## Verification and contract request

See `TestFixtures/live/lm2d/proof.json` and `transcript.md` for the private real-Claude run.
The host uses production runtime, bridge, rules and journal stores, a fixed fixture key, private tmux,
disposable HOME/config and a localhost synthetic model; no user agent configs or credentials.
Run `python3 -B Zeus/App/Tests/Runtime/PhaseDLiveProbe.py` from this worktree.

PM should add the API, receipt, bounds, spend-always-asks rule, outcome deltas, reflection v2 and
locked-storage behavior above to CONTRACT §13. The optional capabilities keep existing app seams
source-compatible. No Shared, CONTRACT, Package.swift, project.yml or scripts changes were made.

## Full-suite limitation during this round

After test keys/file protection were isolated, the encrypted focused suites passed while the console
remained locked. Ordinary full app runs on both platform and appdev still hit managed-fixture deadline
cascades. Appdev also reproduced without render opt-in or overlapping probes. Its samples show the
64-dispatch-thread soft limit reached, with many AppKit `NSAnimation._runBlocking` workers; the main
thread in the ordinary-run sample was pumping the XCTest/AppKit run loop. This is a remaining full-suite
gate blocker, not evidence of a green full suite. See appdev's `LM2DVerification.md` and its
`build/lm2d-standard-test-sample.txt` / `build/lm2d-full-test-sample.txt` for the recorded samples.

One fixture issue was independently corrected here: the MainActor `ScreenLearningTests` called
synchronous Vision OCR directly. Its two verification OCR calls now use a utility queue continuation,
retaining the real recognition assertions and leaving the test host's main actor free. This does not
claim to resolve the separate native-animation worker saturation.

Final core verification: 72 focused tests in 10 suites pass, including the exact-wrap captured Undo
regression, retention during unavailable storage, and real OCR. The private Claude proof consumes and
acknowledges both reflection and Undo on attempt 1. The narrow verifier fix accepts a next word at an
exact right-edge wrap, while continuing to compare the entire owned paragraph and reject edited text.
