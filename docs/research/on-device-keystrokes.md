# Keystrokes for Level 4 "Typing" (LM2-D3 spike)

**Question:** how can Zeus record what you type, per allowed app, so that nothing private is kept, and what should it store?

**Answer in short:**
- **Capture:** a listen-only event tap turns hardware key-downs into text with the active layout. Each key costs under 10 µs.
- **Grouping and gates:** keys are grouped into **runs** per app and window. A run ends after a 2-s gap or a focus change. Secure input, private windows and pastes are hard gates.
- **What leaves memory:** a run is redacted by **both** Redactor stages before it leaves memory. The on-device model turns it into a one-line **topic**.
- **What's stored:** topics for 30 days, and the redacted words of runs for **24 hours** by default. "Topics only" is one switch away.
- **Apple Intelligence:** Level 4 needs it. Without it, Zeus keeps neither the words nor the topics.

**Conditions:**
- M1 Pro, macOS 27.0, Xcode 27.0, Apple Intelligence on.
- Run with a disposable `HOME`. The program is `docs/research/on-device-spike/keys.swift`; build it with `xcrun swiftc -O -swift-version 6 keys.swift -o keys && HOME=$(mktemp -d) ./keys`.

**Isolation (enforced in the program):**
- The only tap whose callback runs is a **per-process tap on the spike itself** (`CGEventTapCreateForPid(getpid())`).
  - Its callback first reads `eventSourceUserData` and passes through, unread, anything without the spike's marker.
  - Every marked key is synthetic and posted only to the spike (`postToPid`).
- The system-wide HID tap is created, checked and removed with no run loop in between, so its callback never runs.
- The paste test uses a private named pasteboard.
- The real keyboard, general pasteboard and other apps are never observed. The output reported 0 unmarked events.

## 1. Measurements

### Capture and translation

| What | Result |
|---|---|
| Input Monitoring preflight (`CGPreflightListenEventAccess`, no prompt) | true for the shell running the spike. Zeus will need its own grant. |
| System-wide tap `.cghidEventTap`, listen-only, key-down | created in 5.5–12 ms, enabled |
| Per-process tap | needs a window-server connection first (`NSApplication.shared`). Without one, `CGEventTapCreateForPid` returns nil. |
| `UCKeyTranslate` with the event's layout and carried dead-key state | US: "hello É é" (⌥E dead key, then ⇧E and E) ✓ · German: "zy ä" (QWERTZ) ✓ · French: "aq ê" (AZERTY, ^ dead key) ✓ |
| Callback + translate, per key | median 0.2–8 µs, p99 4.5 µs, worst 85 µs (first key) |
| 2,000 keys | 2,000 seen, none lost |
| Synthetic vs hardware keys | Synthetic keys carry a private `eventSourceStateID`; hardware keys carry `hidSystemState` (1). **Record only `hidSystemState` keys.** That excludes password managers' auto-type, other apps' automation and anything Zeus itself posts. |
| A slow callback (1.5 s) on a listen-only tap | **No** `tapDisabledByTimeout`. Listen-only taps aren't disabled for slowness, but a slow callback still delays the keys behind it. |

### Secure input (password fields)

| What | Result |
|---|---|
| `EnableSecureEventInput()` → `IsSecureEventInputEnabled()` true | median 0.75 ms, max 3.7 ms (n=20) |
| Cost of `IsSecureEventInputEnabled()` | < 50 ns (effectively free to check on every key) |
| A key posted while secure input is on | **did not reach the tap** |
| `NSSecureTextField` made first responder in a background app's window | secure input stayed off. AppKit turns it on only for the active app's key window, so a real password field turns it on at focus, before the first key. |

- **When does it flip?** Secure input turns on when the password field takes focus, not on the first key. So the first character typed into a password field never reaches a tap. The key that *moved* focus (Tab or a click) does, and that's harmless.
- **The gate is still Zeus's job:**
  - Check `IsSecureEventInputEnabled()` on every key.
  - When it turns on, **end and discard the current run**, because its last keys may have been the user's name or username before the password.
  - Record nothing until it turns off.
- Testing this end to end needs a frontmost app with a real password field. The spike didn't do that, because activating it would take focus from the user. Platform should cover it in a harness that runs as the active app in a test session.

### Input Monitoring denied or revoked

- **Denied:** `CGEvent.tapCreate` returns nil, and `CGPreflightListenEventAccess()` is false.
- **Revoked while running:** not measured, because revoking needs the user to act in System Settings. Apple documents no callback for revocation. The tap simply stops receiving events, or the system sends `tapDisabledByUserInput`. **Recommendation:**
  - Re-check `CGPreflightListenEventAccess()` every 60 s while Level 4 is on, on wake, and on any `tapDisabled…` event.
  - When it reads false, close the tap and show the revoked state (`PRIVACY.md` §10.4).
  - When it's back, re-create the tap.
  - Never call `CGRequestListenEventAccess()` outside the consent flow.

### Runs

The coalescing logic was run on a synthetic stream:
- A gap of more than 2 s ends a run, and so does a change of app or window.
- Backspace removes the last character of the current run. A backspace with no run doesn't start one.
- ⌘V adds `‹pasted›` and never reads the pasteboard.

Output:

```
[Mail · Re: Appointment] 8.1s: "Hi Dr Osei, can we move Thursday to 3pm? My knee is still sore."
[Terminal · zsh] 2.0s: "token: ‹pasted› curl api" (1 paste)
[Xcode · ManagedSessionController.swift] 1.8s: "fix restart race"
```

- **Costs:** coalescing is 0.1 µs per key, and reading the pasteboard `changeCount` is 0.8 µs, only on ⌘V.
- **What a paste looks like:** the tap only sees keys, so pasted text never enters a run as text. ⌘V (and `changeCount` moving) just marks that something was pasted.
- **Menu-bar Paste or drag-and-drop** produce no keys, so nothing is recorded.

### The Redactor on runs vs prose

The test used 8 synthetic pairs with 11 planted private details. Each typed run is the same words as the prose, typed casually: lower case, no punctuation, run together.

| | Typed runs | Prose |
|---|---:|---:|
| Stage 1 (patterns + `NSDataDetector` + `NLTagger`) | **6 / 11** | 8 / 11 |
| Stages 1 + 2 (with the on-device model's prose pass) | **11 / 11** | 10 / 11 |

- **Stage 1 alone is much weaker on typing.** `NLTagger` relies on capital letters for names ("priya", "osei"), and amounts and PINs lose their punctuation.
- The model pass closes the gap at about **1.5 s per run**. So for Level 4 the model pass is **required, not optional**: no Apple Intelligence means no Level 4.

### Topics (on-device model, `TypingTopic`)

| App | Typed (synthetic) | Topic |
|---|---|---|
| Mail | "hi dr osei can we move thursday to 3pm my knee is still sore" | replying · "Request to reschedule appointment time" · doctor |
| Mail | "send it to maria.lopez@… and cc jonas" | replying · "Project update" · colleague, manager |
| Messages | "call me on 555 0147 after 6" | replying · "Scheduling a call" · colleague |
| Notes | "my pin is 4471 dont share" | replying · "Security code" · support team |
| Safari | "card 4242 … exp 0428" | filling · "Payment details" · bank |

- **Latency:** 1.4–1.8 s warm, 6.5–6.8 s cold.
- **Quality:** none of the topics contains a name, number or health detail, and recipients come out as roles every time.
- **Weak spot:** the intent is sometimes wrong (a note was labelled "replying"). That's acceptable for a journal, and app plus intent can be corrected by rules later.

## 2. What to store: runs or topics?

**Recommendation: topics for 30 days, and the redacted words of runs for 24 hours by default**, with a "Keep the words" control of **Don't keep / 24 hours / 7 days**.

- **Topics** carry what the assistant needs ("replying to a doctor about rescheduling") without the words. They're the safest thing to keep for a month, and the only thing summaries and reflection use.
- **Words** are what users will want to check ("what did Zeus see me type?"). They're also the most sensitive thing Zeus could hold, and stage 1 alone misses about half of what's private in casual typing. Even with stage 2 they carry the highest residual risk. So keep them briefly, show them exactly as stored, and let people turn them off.
- **"Don't keep" (topics only)** is the right choice for anyone who wants Level 4's help without a typing log. Suggest it in the consent sheet.
- **Words never leave the Mac.** Topics do, in summaries. On-demand access to words for the assistant (Phase D's `zeus_get_journal`) needs the per-level "raw on request" switch, which is off by default.

## 3. Recommended pipeline and per-key budget

| Step | Where | Cost |
|---|---|---|
| Tap: listen-only `.cghidEventTap`, key-down and flagsChanged | callback | < 10 µs per key |
| Gates, per key: keep only `hidSystemState` keys; secure input off; front app allowed (Level 4's coin is **only** "apps I choose"); not a private window; not locked | callback | < 1 µs |
| Translate (`UCKeyTranslate`, dead-key state per run); skip ⌘/⌃ chords except ⌘V; skip IME input sources (`kTISPropertyInputSourceType` = input mode), which record "typed in <app>" only | callback | < 10 µs |
| Append to the in-memory run; end it on a 2-s gap, app or window change, secure input (discard), or 2,000 characters | callback | 0.1 µs |
| On run end: hand off to a `.utility` task | — | — |
| Redactor stage 1 + stage 2 (model required) → if either fails, **drop the run** (fail closed, as in Phase A) | task | ≈ 1.5 s per run |
| `TypingTopic` from the redacted run | task | ≈ 1.5 s per run |
| Store the topic (30 d) and the redacted run (by the retention choice) | task | — |

- **Budget:** under 25 µs per key on the tap thread, which means no typing lag. About 3 s of model time per run, off the main thread, at `.utility`.
- **At a heavy 300 runs a day**, that's about 15 min of mostly Neural Engine time spread across the day. Batch up to 5 runs per call when the queue backs up.
- **Low Power Mode or < 30 % battery:** hold redacted-by-stage-1 runs **in memory only** for at most 10 min. If the model still can't run, drop them.

## 4. Schema (for platform)

```swift
@Generable(description: "What a person was doing in one stretch of typing, without the words they typed")
struct TypingTopic {
    @Guide(description: "The app they typed in, by name")
    var app: String
    var intent: TypingIntent
    @Guide(description: "What the typing was about, in at most 8 words. A topic, not a quote. No names of people, no numbers, no addresses, no secrets.")
    var subject: String
    @Guide(description: "Who it was for, as roles only (for example: colleague, manager, client, doctor, family member, support team). Never names. Empty if unclear.", .maximumCount(3))
    var recipients: [String]
}
@Generable enum TypingIntent { case replying, drafting, searching, coding, notes, commanding, filling, chatting, other }
```

- **Instructions:** *"You summarise what someone was doing while typing, for their private activity journal. Give a topic, never a quote. Never include names of people, numbers, addresses, health details or secrets; describe recipients only by their role."*
- **Prompt:** `App: <name>\nTyped: <redacted run>`.
- **Settings:** greedy sampling.
- **After generation, post-check `subject` and `recipients`:**
  - Run stage 1 on them.
  - If anything matches, or a recipient isn't one of the role words, replace the recipients with an empty list and the subject with "<intent> in <app>".

## 5. Open points

- **The live secure-input path** (a real password field in the active app) and **revocation at runtime** weren't measured. Both need an owned, frontmost test app in a test session, so they belong to platform's harness.
- **IME languages** (Japanese, Chinese, Korean) get counts only in v1. Committed IME text would need `NSTextInputClient`-level access that Zeus doesn't have.
- **Autocorrect and autocomplete** change text after the keys, so a run can differ from what was sent. The viewer copy says "what you typed", not "what you sent".
