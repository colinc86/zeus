# LM2-C core integration

## Composition and lifetime

`TypingSeams.swift` defines the observer/context/policy. `Seams.swift` adds optional `JournalPayload.topic` (old Codable
rows decode nil), `TypingWordsRetention` and optional `TypingJournalStoring`. No Shared or CONTRACT file is changed.

```swift
let window = TypingWindowContextSource(policy: { typingPolicy }, isLocked: { focus.isLocked },
    browserPrivacy: { identity in positivelyKnownPrivacy(identity) })
let typing = TypingObserver(journal: journal, redactor: redactor,
    policy: { typingPolicy }, context: { window.current() })
window.start { [weak typing] in typing?.contextDidChange() }
typing.start()
// Disable/shutdown: window.stop(); typing.stop().
```

Both `enabled` and `consented` are required. `apps` is always an allow list; empty records nothing, and `privateApps` wins.
The app expands its private-list names to the current bundle ID too, as for Levels 2/3. The source reads only app identity
and opaque front-window ID, never a title, URL or selection. It reuses the screen source's notification ownership but
never its title-reading method. Unknown browser privacy fails closed. A normal/private result must be bound to exact
bundle/PID/window identity; any explicit Safari exception belongs to the level-4 app policy and its consent, never an
inferred global browser grant. The source never asks for AX or Input Monitoring permission.

App policy changes: invalidate pending work, persist the exact new policy, call the store's `pruneTyping`, update context,
then start/stop as appropriate. Before journal forgetting, call `typing.invalidatePendingCapture()` alongside the L1–3
invalidations. Lock/private/secure/permission stops discard the current and suspended runs. An ordinary permitted
app/window switch completes the old run; before committing it, the observer rechecks both its app policy and the current
hard stops. The tap is listen-only and hardware-origin only. Production never accepts the native harness's synthetic
override; that initializer creates only a marked per-process tap, never a global tap.

`permission`, `lastPermissionRequestGranted`, `permissionGrantedRequiresReopen`, `pause`, `privateInput`, `isRecording` and
`lastError` are presentation hooks. Only `requestPermission()` may prompt, from the app's explicit consent flow. A false
CoreGraphics permission result cannot establish an allowed/reopen state. Permission and secure input are checked by the
one-second watchdog, on context/wake events, and before keys/commit; this is stricter than the 60-second revocation bound.
Secure input is checked before context metadata or key translation. Its menu-only state clears when typing is off;
there is no avatar alert, thread card or VoiceOver announcement from the core. Revocation records one text-only journal
outcome and closes the tap. Public permission Boolean APIs do not provide the reason for a failed tap creation.
Positive request evidence is cleared when permission becomes usable; a later revocation cannot reuse it to claim Allowed.

## Runs and model gates

UCKeyTranslate retains the current keyboard layout data and dead-key state; layout changes replace it. Backspace edits
the last grapheme (or cancels a pending accent); cursor/control commands invalidate an unrepresentable draft. A run ends
at a two-second gap, permitted app/window change or 2,000 characters. Command-V variants add `‹pasted›` using only the
pasteboard change count, even when the same clipboard is pasted twice. Menu Paste and drag/drop supply no key text.
No general pasteboard content is read. IME input sources record counts and `Typed in <App>` only, with neither words
nor topic. Autocorrect/completion/cursor edits are not reconstructed: this is an observation of typing, not sent text.

Stage one always runs before queued/deferred work; raw words never go to disk or logs. The queue holds at most 20
stage-one results in RAM and expires them at ten minutes. Low Power Mode/battery below 30% defer model processing.
One worker processes runs serially at utility priority. Entire secret-only runs are dropped. `RunRedactor` requires
`semanticEngine == onDeviceModel`; unavailable/busy/error/guardrail/timeout never falls back to retaining stage-one
words. The observer exposes a content-free error after a declined semantic pass and retains no row.

`TopicSummarizer` receives redacted words only. It uses the designer's structured schema, greedy on-device generation,
an eight-second budget, and fresh sessions. Stage-one post-checks cover subject/role recipients; numbers, placeholders,
private spans or non-role recipients produce a generic intent-in-app topic with no recipients. Subjects are bounded
to eight words. If topic generation fails **after mandatory run redaction succeeded**, NLTagger supplies app/typing/
word-count only. It never substitutes original words for a missing topic. Apple Intelligence unavailable disables the
entire observation path; there is no cloud model.

## Payload and retention

One `JournalItem` per stretch: `.level = .typed`, `.kind = .typedText`, ID equal to `details["run_id"]`.

| Field | Meaning |
|---|---|
| `payload.topic` | Optional safe one-line topic; never substitute words/description when absent |
| `payload.description` | Same topic, or the IME app/count description |
| `payload.text` | Optional already-redacted words, never raw keystrokes |
| `details.appName` | Redacted app label; `JournalItem.app` is the bundle ID |
| `details.intent`, `recipients` | Safe topic intent and role-only comma-separated recipients |
| `details.topicEngine` | `onDeviceModel` or `naturalLanguage` fallback |
| `details.pasteCount` | Number of paste shortcuts in a non-IME run |
| `details.inputMethod`, `keyCount` | IME-only count metadata |
| `details.words_expires`, `topic_expires` | Absolute epoch-second deadlines, numeric strings |
| `details.words_not_kept` | `setting`, `shortRun`, `expired24Hours`, `expired7Days`, `inputMethod`, or empty while kept |

Words: `.none`, `.day` (24 h default), `.week` (7 d); fewer than three words are topics only. Topics: task/PM choice
7/30/90 d, default 30, overriding the older design draft's fixed 30. Word choices cannot exceed topic retention (all
topic choices are at least seven days). `pruneTyping(words:topicsDays:now:)` immediately applies shortening; the old
`pruneTyping(words:now:)` overload defaults to 30 topic days. Longer word preferences never extend a saved word deadline
or restore removed words. Rows record the original deadlines. General `JournalRetention.typedDays` should also use
the app's chosen topic days. Other levels and the nondeletable sent ledger are untouched.

The encrypted store independently schedules the next typing deadline and enforces expiry before query/search/export,
including after sleep and with capture off. No future timer retains its store. A failed retention write fails reads
closed until it can remove disallowed words. Single-run Undo through append also respects the last applied policy.

`.item(runID)` deletes the one topic/words row. `deleteTyping(ids:) -> TypingDeletionReceipt` atomically deletes an
app/hour group in one encrypted day file; missing IDs, non-typing rows or cross-day groups fail before any deletion.
`restoreTyping(_:)` restores the group only when all IDs are absent and the store's forget epoch still matches. It rejects
forgotten/changed/expired groups and strips expired words. Retention shortening invalidates stale group Undo tokens.
Receipts are in-memory, scoped to that store instance, not durable exports. The viewer may use receipts for both single
and grouped Undo; deletion preserves unrelated rows in the same file.

Morning L1 digests and runtime reflection sample at most four evenly spaced `payload.topic` strings. Frames, typing
words, IME descriptions and other fallback text never enter those summaries. Existing L1 morning-trigger behavior is
unchanged; reflection can be enabled by Level 4 independently through the app's enabled/context adapters.

## Verification and native limits

Recorded US/German/French layout/dead-key sequences; fake-clock gap/focus/size/backspace/paste/IME tests; every privacy
stop; after-await invalidation and Stop; mandatory semantic refusal; schema post-check; exact separate retention;
atomic delete/failed-write/Undo/forget; and topic-only reflection are covered in `TypingLearningTests`,
`LearningRuntimeTests` and `LearningStoreTests`. App tests inject sources/models and never install global taps.

The isolated native dev-host gate is **blocked** by Input Monitoring preflight false. An independent synthetic model
probe observed guardrail refusals and a topic execution failure under `CriticalMemoryPressure`. No successful native
typing/model proof is claimed. See `TestFixtures/live/lm2c/README.md` for evidence, isolation and opt-in commands. Nothing
was done to the user's TCC settings, clipboard, agent config or input source. LM2-R rule-notice copy is unchanged.
