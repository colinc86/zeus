# Privacy surfaces: Learn from me, the journal and rules

The spec for everything the user sees about what Zeus observes, keeps, sends and decides (LM2 Phase A, levels 1–2, rules).
Copy in quotes is final unless the code needs to shorten it, in which case ask the designer.
Settings uses the system font and the existing Settings components (`settingsTitle`, `settingsBody`, `settingsCaption`, `settingsError`, `SettingsSegments`, `KeyboardButton`, `SettingsDivider`). There are no new ZeusDesign tokens.
Renders: `scripts/design-harness/render.sh "privacyMockups()"` → `build/q2-renders/lm2-*.png`, copied to `docs/design/lm2/`.

**Status by section:**

| Section | Phase | Status |
|---|---|---|
| §1–8: principles, Settings › Privacy levels 1–2, the coin and lists, What Zeus Kept, Settings › Rules, quiet lines, drop on Zeus, first run | A | ships in Phase A |
| §9 Level 3 · Screen, Ask About This | B | shipped (LM2-B-A) |
| §10 Level 4 · Typing | C | shipped (LM2-C-A) |
| §11 Raw on request, journal answers, acting rules, outcomes in Why? | D | shipped (LM2-D-A) |
| §4.2 Waiting group and empty states, §6.1 delivery, hold and stale-setup lines | LM4 | building (LM4-A, on LM4-P's seams) |
| §12 The assistant folder: folder row, Cover pictures and faces, the new caption, Show in Finder, Delete Everything | LF1 | building (LF1-A, on LF1-P's seams); §11.1 retired |
| §13 Ratings: what is kept, sent and written to the folder; the ledger rows; Delete Everything | FB1 | shipped (0.2.7); the surfaces are in `CONVERSATION.md` §17 |

## 1. The seven principles

These are the README promise. Every surface below exists to keep one of them visible.

1. **Nothing leaves your Mac by Zeus's hand.** What Zeus keeps goes into your assistant's folder after the safeguards (§12); your assistant decides what it reads and where it sends it.
2. **Private details are removed before anything is stored**, not just before it's sent. Nothing goes to disk unredacted.
3. **Every level is its own switch, off by default.** Turning one on shows exactly what it keeps, with an example record.
4. **Some things are never recorded:** password fields (secure input), private browser windows, apps on your private list, and a locked screen.
5. **You can see everything Zeus kept and everything it sent**, exactly as stored and as sent.
6. **Delete is immediate and complete:** one item, a day, an app, or everything.
7. **Summaries go to your assistant's model provider**, like any message you send. The consent sheets say so.

## 2. Settings › Privacy

> **Phase A: ships in Phase A.**

Top to bottom:

1. **Status line** (caption). Shown only when at least one level is on. Exact wording:
   - Apple Intelligence on: "Private details are removed on this Mac before anything is kept."
   - Apple Intelligence off: "Private details are removed on this Mac before anything is kept. Apple Intelligence is off, so Zeus catches names, emails, phone numbers, addresses, passwords, keys, card and account numbers and ID numbers, and may miss private details written in other ways."
1b. **Storage problem** (`settingsError`, under the status line, only while the journal or rules store can't be opened): "Zeus can't open its journal and rules right now. New records are kept only in memory until it can; quitting Zeus before then loses them." It clears by itself.
2. **Level 1 · "Apps and timing"**: the existing L1 section (switch "Let Zeus learn when and in what I work", private list, retention, "What Zeus has recorded"). Its title changes from "Learn from me" to "Apps and timing", and the pane's first title is now "Learn from me" above all levels. While the switch is off, everything under it is disabled, including "Keep activity for" (UX5).
3. **Level 2 · "Windows and pages"**: §2.1.
4. **What Zeus sends your assistant** (UX5): §2.5. The former "Notes to your assistant" block, moved out of Level 1 and widened to every kind.
5. **What Zeus kept**: §4.
6. **Pause for Today / Delete Everything…**: unchanged. "Delete Everything…" now covers the whole journal.

### 2.5 What Zeus sends your assistant (UX5)

One place that lists everything Zeus sends, in the ledger's words (§4.2), each with its timing and its switch or a
pointer to it. Title `settingsTitle` "What Zeus sends your assistant", caption "Each one goes to your assistant like a
message, with private details removed first. The exact text is in What Zeus kept." Then six rows, each a
`settingsBody` title and a `settingsCaption` line, in this order:

| Row | Caption | Switch or pointer |
|---|---|---|
| Morning summary | "Each morning, a short summary of the day before." | "Sent while Apps and timing is on." (the row is disabled when it's off) |
| Notes | "Up to four a day, when something changes:" | the four checkboxes, disabled while Apps and timing is off |
| Evening reflection | "Each evening, a summary of the last 28 days: your rhythm, focus and recurring tasks, with private details removed." | "Sent while any level is on." |
| Morning brief request | "At the start of your day, Zeus asks your assistant for one short brief of what matters today. It goes even when Learn from me is off." | "On." or "Off." then an "Assistant Settings" button (opens Settings › Assistant at Morning brief) |
| Rule trigger | "When one of your rules fires: the rule, what matched and the window." | a "Rules" button (opens Settings › Rules) |
| Message preference | "When you rate a message: what you'd rather have, and nothing else." | "Sent as you rate." |

- The four note checkboxes keep their labels and defaults (all on).
- VoiceOver reads each row as "<Row>. <caption> <switch sentence>"; the buttons by their labels.
- **First-run sheet** ("Learn from me", §8): its first sentence becomes "Zeus records how you use this Mac so your
  assistant can pick better moments to help. Each morning it sends your assistant a short summary of the day before,
  and each evening a summary of the last 28 days: your rhythm, focus and recurring tasks." The two lists are unchanged.
- **Folder row** (§12.2): in Connect-your-own mode, while "Choose…" is disabled because Zeus has no journal to write
  from, a caption under the buttons says why: "Zeus can't open its journal right now, so there's nothing to keep in a
  folder yet."
- **Morning brief schedule** (AGENT_LEARNING.md §8.4): both choices carry a detail line.

Levels 3 ("Screen", §9) and 4 ("Typing", §10) follow Level 2 in the same style, each with its own switch; the pane shows the four levels, then What Zeus kept and the global actions.

### 2.1 A level section (Level 2 shown)

```
Windows and pages                                    [title]
[ ] Let Zeus keep window titles and web addresses      [switch]
Zeus keeps the title of the window in front, the file it shows, and
the address of the web page, so your assistant knows what you were
working on. Never what's inside the window.           [caption]

Record in   ( Everywhere except my private list | Only in apps I choose )   [SettingsSegments]
<list, see 3>
Keep for    ( 7 days | 30 days | 90 days )                                  [SettingsSegments, default 90]
```

- Turning the switch on the first time opens the consent sheet (§2.2). Later it turns on directly.
- While macOS permission is missing, an extra caption line shows under the switch (§2.3).
- With the switch off, the rest of the section is disabled (dimmed), not hidden.

### 2.2 Consent sheet, Level 2 (one time)

Same frame as the L1 sheet.

- **Title:** "Windows and pages"
- **Body:** "Zeus keeps the title of the window in front, the file it shows and the web address, so your assistant can tell what you were working on and help at the right moment."
- **"Zeus keeps"**
  - "The title of the window in front, when it changes"
  - "The file a document window shows"
  - "The web address in Chrome and Edge" (only browsers that tell Zeus which windows are private; appdev adjusts the list to what the capture supports)
  - "The subject of the Mail message you're reading"
- **"Zeus never keeps"**
  - "What's inside a window: text, pictures, messages"
  - "Anything while a password field is active"
  - "Private windows in Chrome and Edge"
  - "Apps on your private list"
- **"An example of what's stored"**: a monospaced block in the field chrome. The synthetic record shows two redactions:
  ```
  09:41  Mail     Subject: Lunch with ‹name› on Friday
  09:44  Chrome   Q3 planning – Docs · docs.example.com/d/‹id›
  09:52  Xcode    ManagedSessionController.swift — Zeus
  ```
  - Caption under it: "Names, emails, numbers and other private details become placeholders like ‹name› before anything is stored."
- **Safari line** (caption): "Safari: Zeus keeps only that you used it. To keep its titles and web addresses too, add Safari under Only in apps I choose. Zeus can't tell Safari's private windows apart, so those would be kept too."
- **Caveat** (caption, LF1 wording): "The records go into your assistant's folder, and summaries of them go to your assistant like any message. Where that goes depends on the assistant you chose."
- **Permission** (caption): "Next, macOS asks you to allow Zeus under Accessibility. Zeus uses it only to read window titles."
- **Buttons:** "Not Now" (cancel, Escape) and "Continue" (default).
  - Continue turns the level on and starts the permission flow (§2.3).

### 2.3 Permission flow (Accessibility)

1. After Continue, Zeus calls the system prompt once. If it isn't granted yet, a caption line shows under the switch: "Waiting for Accessibility permission. · Open System Settings". The link opens Privacy & Security › Accessibility.
2. Once granted, the line goes. No sheet, no sound.
3. If it's revoked later: "Accessibility is off for Zeus, so window titles aren't kept. · Open System Settings". The level stays on, and nothing is recorded at Level 2 until it's granted again. Level 1 keeps working.
4. The thread never mentions permissions. This lives in Settings only.

### 2.4 Levels 3 and 4

- **Level 3, "Screen":** §9 (shipped in Phase B).
- **Level 4, "Typing":** §10 (shipped in Phase C). Both sections' Raw on request switches are §11.1.

## 3. The coin and the lists

> **Phase A: ships in Phase A.**

`SettingsSegments` labelled "Record in", with two choices:

**1. "Everywhere except my private list"** (default)
- The **one private list** is shared by every level and shown once, under Apps and timing. Higher levels in this mode don't repeat it (LM2-R A3). Their caption reads: "Apps on your private list (above) are never recorded at any level."
- Caption: "Apps on your private list are never recorded at any level. Time in them counts only as private."

**2. "Only in apps I choose"**
- The list below is this level's own **allow list**. The private list still wins.
- Caption: "Zeus records this level only in these apps."
- Empty state (caption): "No apps chosen yet, so nothing is recorded at this level."

**Safari** (PM decision, LM2-D):
- Safari is app-only by default in every mode.
- Its titles and addresses are kept only when the user adds Safari to Level 2's allow list ("Only in apps I choose").
- When Safari is in that list, its row gets a caption under it (`settingsCaption`, one line): "Private windows can't be told apart, so their titles and addresses are kept too."
- Adding Safari shows no extra confirmation. The caption is the warning.

**List rows** (both lists):
- App icon (16 pt), the app name in `settingsBody`, and a trailing "–" `KeyboardButton`.
  - VoiceOver label for the "–" button: "Remove <App>"
- Under the list:
  - "Add App…" opens an open panel on /Applications. The panel message is "Choose an app to keep private." or "Choose an app Zeus may record."
  - Result line, existing L1 wording: "Added <App> to your private list." or "Added <App>."

## 4. What Zeus kept (viewer)

> **Phase A: ships in Phase A.**

**Entry point:** "Open What Zeus Kept…" button in Settings › Privacy. It opens a window titled "What Zeus Kept", about 720×520, resizable.

**Two segments at the top:** "Kept on this Mac" and "Sent to your assistant".

### 4.1 Kept on this Mac

- **Toolbar row:**
  - Day stepper "‹ Today ›" (then "Yesterday", then "Mon 12 Oct").
  - Level filter: "All levels", "Apps and timing", "Windows and pages".
  - App filter: "All apps", then one entry per app.
  - Search field, placeholder "Search what Zeus kept".
- **Rows** (newest first): time · app icon + name · the record exactly as stored.
  - Placeholders (`‹name›`, `‹email›`…) are drawn in `secondaryText`, so redactions stand out.
  - Private time reads "Private · 12 min". Safari without details reads "Safari · details not kept".
- **Row actions:** on hover and in the context menu, "Delete". VoiceOver gets "Delete" as a custom action.
  - Deleting a row removes it at once with no confirmation, and the footer shows "Deleted. · Undo" for 5 s.
- **Footer buttons and their confirmations:**

  | Button | Confirmation text | Confirm button |
  |---|---|---|
  | "Delete This Day…" | "Delete everything Zeus kept on <day>? This can't be undone." | "Delete Day" (destructive) |
  | "Delete <App>…" (only with an app filter) | "Delete everything Zeus kept from <App>, on every day? This can't be undone." | "Delete" |
  | "Export…" | none; a save panel suggests "Zeus Journal <yyyy-MM-dd>.json" | — |

  Export writes what is stored (already redacted). Caption by the button: "Exports what's shown, as stored."
- **Empty states:**
  - "Nothing kept on this day."
  - With filters: "Nothing matches."
  - With every level off: "Learn from me is off, so Zeus keeps nothing."

### 4.2 Sent to your assistant (the ledger)

- **Rows** (newest first), one title per kind. This is the vocabulary for everything Zeus sends, used the same way in the
  ledger, the thread (§6.1) and Settings › Privacy (§2, "What Zeus sends your assistant") (UX4/UX5):
  - "Morning summary"
  - "Evening reflection"
  - "Morning brief request"
  - "Note"
  - "Rule trigger: “<rule sentence>”"
  - "Message preference"
  - "Restart notice" (FX15: Zeus restarted the assistant and tells it so, with the time and the reason)
  - "Answer to “<question>”" (Phase D)
- **Each row shows:** time · kind · session label ("■ Claude · Zeus") · size ("212 words").
  - Click to expand the exact text that was sent, read-only and selectable.
- **Caption at the top:** "Everything Zeus sent your assistant about you. Your assistant's model provider received these like any message."
- **No delete here:** the ledger records what has already been sent. Clearing it is part of "Delete Everything…".
- **Waiting group (LM4-A).** A row appears in the ledger only when the assistant has acked the delivery. Items Zeus has prepared but the assistant hasn't received yet sit above the day groups under one heading, "Waiting", newest first, so an empty "Sent" list is never a mystery.
  - Under the "Waiting" heading, a caption scopes the top caption, which otherwise reads as if these were received: "Your assistant hasn't received these yet."
  - A waiting row reads: kind · size · "Waiting since 00:12 · <reason>". No session label: no session has received it. The time is today's clock time, or "Tue 00:12" from another day. Click expands the exact text that will be sent, as for a received row.
  - The reason comes from the platform's `DeliveryHold.reason`, and at most one action follows it:

    | Reason | Text after "Waiting since 00:12 · " | Action |
    |---|---|---|
    | `.disconnected` | "your assistant isn't connected" | "Start Assistant" when Zeus runs the assistant and it's off; otherwise none |
    | `.draft` | "unsent text in its Terminal" | "Open in Terminal" |
    | `.busy` | "it's busy" | none |
    | `.olderSetup` | "it was started with an older setup" | "Restart Assistant" |

    "Terminal" is the app, capitalised as everywhere else in Zeus; "unsent text" matches the draft card ("Your assistant has unsent text in Terminal") and the menu line ("Waiting on unsent text in Terminal").
  - While the Waiting group is shown, the received rows below it sit under a "Received" heading, so the two groups read as a pair. Without waiting items the ledger looks as before.
  - Both row kinds share one disclosure: `ZeusGlyph(.right)`, rotated when expanded, in `secondaryText`, hidden from VoiceOver.
  - When the hold clears and the delivery is acked, the row moves into its day with the usual session label. The group disappears when nothing is waiting.
  - "Export…" on this segment writes received rows only, never waiting ones; its caption reads "Exports the received items shown, as stored."
  - VoiceOver: "Morning summary, 212 words, waiting since 00:12, your assistant isn't connected", then the action's own label.
- **Not sent group (UX4).** A request Zeus discarded without a receipt (a newer one replaced it, or its day passed) is not
  silently gone: it sits under its own heading, "Not sent", between Waiting and Received, for 7 days from the discard,
  newest first. A row reads: kind · size · reason. No session label and no action; View expands the exact text that
  was prepared, as for the other rows.

    | Why | Reason text |
    |---|---|
    | A newer brief request was prepared | "Replaced by today's brief request" |
    | A newer reflection was prepared | "Replaced by a newer reflection" |
    | The brief's morning passed | "Not sent: the morning passed before your assistant could read this brief." |
    | The reflection's day passed | "Not sent: the day passed before your assistant could read this reflection." |

  - The same sentences rewrite the item's thread line in place (§6.1), so the thread and the ledger never disagree.
  - "Export…" writes received rows only; Waiting and Not sent rows are never exported.
  - VoiceOver: "Morning brief request, 93 words, replaced by today's brief request", then "View exact text".
- **Empty states (LM4-A, UX4, UX5).** The empty caption never shows while a Waiting or Not sent row exists.
  - Nothing was ever prepared: "Nothing yet. Zeus sends a morning summary, notes during the day and an evening reflection."
  - Every level off, morning brief off: "Nothing yet. Learn from me is off, so Zeus has nothing to send."
  - Every level off, morning brief on: "Nothing yet. Learn from me is off. Zeus still asks for a morning brief; see Settings › Assistant."
  - Something was received on another day: "Nothing received on this day."

## 5. Settings › Rules (new tab)

> **Phase A: ships in Phase A.**

- **Tab:** title "Rules", SF Symbol `list.bullet.rectangle`.
- **Placement:** the tab sits after Privacy, and it's hidden until Learn from me is on at any level or a rule exists.

### 5.1 The dial

`SettingsSegments` labelled "New rules", with three stops stored as 0, 0.5 and 1. The default is the middle one (0.5). The caption under it changes with the choice.

| Stop | Caption |
|---|---|
| "Ask me first" | "Every new rule waits in Suggested until you turn it on." |
| "Balanced" (default) | "Rules about timing and tone start at once. Rules that act for you show what they'd have done once, and wait for your OK." |
| "Just do it" | "Rules start at once. Rules that act for you show what they'd have done and wait for your OK, then act without asking. Undo is always there." |

Rules that act for you (send, post or spend) never skip their first "I'd have…" line, at any stop, and stay in Waiting for your OK until you approve them; the stops differ only in what happens to the rest. "Just do it" also counts the first shadow line as an accepted result, so the rule's confidence rises sooner.

### 5.2 Sections

Each section is a `settingsTitle` with a count. Empty sections are hidden, except Active.

| Section | Holds | Row extras |
|---|---|---|
| "Active" | status active | toggle (on) |
| "Waiting for your OK" | shadow | "Seen once: would have <outcome>" caption (fallback when there is no outcome text: "Seen once. Zeus didn't act."), buttons "OK" and "Not This" |
| "Suggested" | proposed | buttons "Turn On" and "Dismiss" |
| "Retired" (collapsed by default, "Show 3 retired") | retired | "Retired <date>: you skipped it often" or "…turned off", and "Turn Back On" |

Active empty state: "No rules yet. Zeus and your assistant suggest rules from what Zeus keeps, once a day. You can also add your own." Then the "Add Rule…" button.

### 5.3 A rule row

```
Hold Slack messages after 18:00 on weekdays          [settingsBody, 2 lines max]
Weekdays from 18:00 · in Slack · held, not dropped    [caption: the trigger in words]
▮▮▮▯▯ Fairly sure · from your assistant · 3 days ago  [caption]
                                    [toggle]  [ ⋯ ]
```

- **Confidence** is a 5-cell pixel meter (`palette.focusRing` filled, `palette.fieldBorder` empty) plus a word. Never a percentage.

  | Confidence | Cells | Word |
  |---|---|---|
  | ≥ 0.75 | 4–5 | "Sure" |
  | 0.45–0.75 | 3 | "Fairly sure" |
  | 0.2–0.45 | 1–2 | "Unsure" |

  - Below 0.2 the rule moves to Retired.
  - VoiceOver: "Confidence: Fairly sure".
- **Source:** "from your assistant" or "added by you". If the user has edited an assistant's rule, it says "edited by you".
- **The ⋯ menu:** "Why?", "Edit…", "Delete".
  - Delete needs no confirmation and shows "Deleted. · Undo" for 5 s.
- **Why?** opens a popover:
  - Title "Why this rule"
  - The evidence journal items as stored, each "Mon 12 Oct · 18:20 · Slack · …", at most 5, then "and 4 more"
  - "Proposed by your assistant on <date>"
  - If an evidence item was deleted: "Some of the reasons were deleted."
- **Edit… and Add Rule…** use a sheet titled "Edit Rule" or "New Rule":
  - Field "Rule", placeholder "Say what Zeus or your assistant should do"
  - "When" fields: days, a time window, apps ("Any app" / chosen apps), state ("Any" / "Tests failing" / "In a meeting"), where Zeus can enforce it
  - Kind is shown, not chosen: "Changes only when and how Zeus talks to you" (passive) or "Acts for you outside Zeus" (acts)
  - A rule the user writes is always passive. Caption under the kind line in "New Rule": "To have your assistant act for you, ask it. It suggests a rule you can OK."
  - Buttons "Cancel" and "Save"
  - Rules edited by the user count as `updatedBy: user`, and the reflection treats them as strong signal.

## 6. Quiet thread lines

> **Phase A: ships in Phase A.**

These are system lines in the thread: the existing notice style, the same as "Claude Code has an update · Restart assistant". There's no peek and no sound, and each line names the rule.

| Moment | Line | Actions |
|---|---|---|
| A passive rule starts | "New rule: Hold Slack messages after 18:00 · Review" | Review opens Settings › Rules at that rule |
| A rule that acts, first time (shadow) | "I'd have sent “Running late, 10 min” to the team chat · OK next time?" | One action, "OK next time?" → "OK. I'll do that from now on. · Undo". "Not This" is in Settings › Rules. Ignoring the line leaves the rule waiting, and after 24 h it counts as an ignored result |
| Phase A wording (no outcome text yet) | "I'd have acted on “<rule sentence>” · OK next time?"; after OK: "OK. I'll do that from now on. · Undo"; after Not This: "Got it. I won't."; retired: "Retired: “<rule sentence>” · Review" | as above |
| Zeus held messages for a rule | "Held 2 messages for your rule “No interruptions while tests fail” · Show" | Show opens the panel at the first held card |
| A rule retired itself | "Retired a rule you kept skipping: “Prepare PR list at 8:50” · Review" | Review |

- Several new rules from one reflection collapse to one line: "3 new rules · Review".
- Everything quoted inside a line has already been through the Redactor.

### 6.1 Delivery lines (LM4-A)

A line says "Sent" only once the assistant has acked the delivery. Until then the same line says "ready", and it changes in place when the ack arrives: one line, in its original place in the thread, never a second line. View always shows the exact text.

| Moment | While waiting | Once received |
|---|---|---|
| A morning summary | "Morning summary ready for your assistant · View" | "Sent the morning summary · View" |
| A note (moment) | "Note ready: back from a break · View" | "Sent a note: back from a break · View" |
| An evening reflection | "Evening reflection ready for your assistant · View" | "Sent the evening reflection · View" |
| A morning brief request | "Morning brief request ready for your assistant · View" | "Sent the morning brief request · View" |
| A rule trigger | "Rule trigger ready for your assistant · View" | "Sent a rule trigger: “<rule sentence>” · View" |
| A message preference | no line (§11) | no line |
| A restart notice (FX15) | "Restart notice ready for your assistant · View" | "Sent the restart notice · View" |

The kinds are the ledger's (§4.2): one word for one thing, in the thread, the ledger and Settings (UX4).

VoiceOver follows the A12 pattern: "View: Morning summary ready for your assistant", "Hide: …", with Collapsed/Expanded.

**Replaced or expired (UX4).** When a prepared item is discarded without a receipt, its line is rewritten in place
(same id, same spot; a line the user dismissed stays dismissed) and never gets a second line:

| Why | Line |
|---|---|
| A newer brief request was prepared | "Replaced by today's brief request · View" |
| A newer reflection was prepared | "Replaced by a newer reflection · View" |
| The brief's morning passed | "Not sent: the morning passed before your assistant could read this brief. · View" |
| The reflection's day passed | "Not sent: the day passed before your assistant could read this reflection. · View" |

View keeps showing the text that was prepared. The ledger's Not sent group (§4.2) uses the same sentences.

**Long View (UX4).** When the text behind View is longer than about 12 lines (every reflection and brief request; a
note never is), View opens it in the document viewer (CONVERSATION.md §21) instead of expanding inline: a read-only
page built in memory (no file is written), titled "<Kind> · <Day date>", for example "Evening reflection · Fri 17 Oct"
or "Morning brief request · Sat 18 Oct". The header has Back, the title and Expand but no Open (there is no file);
find and selection work; the ⋯ menu offers Copy Text and Find only. Back returns to the line. Shorter text keeps the
inline expansion with "Hide". The line's VoiceOver label is unchanged ("View: …").

**One line per finished day (FX19).** Each delivery adds a line, and a quiet week of summaries, brief requests, notes
and reflections adds up to more of Zeus's own housekeeping than conversation. So once a local day is over, that day's
received lines (every "Sent …" line above, two or more of them) fold into one quiet line at the time of the day's first
delivery: "Zeus sent your assistant 3 things · Show". **Show** lays the day's lines out in place under it, oldest
first, each with its own View exactly as before (inline text, or the reader for long text); the action reads
"Hide" while they show, and Hide folds them again. Showing is presentation only: nothing is marked, sent or
persisted, and a line the user dismissed stays gone from the group. Today's lines never fold (the day is still being
read), nor do live lines: "ready", "Held", hold, stale-setup, "Replaced by …" and "Not sent: …" lines stay on their
own in their original places, so anything that still needs the user stays visible. A day with one received line keeps
that line as it is. VoiceOver: "Show: Zeus sent your assistant 3 things" / "Hide: …", with Collapsed/Expanded, and the
expanded lines as a group "3 lines from this day".

**A hold older than 10 minutes** adds one quiet line per hold, which updates in place and clears itself when the delivery goes through. Under 10 minutes nothing is said; the draft card (CONTRACT §12, P2) already covers a user message stuck behind a draft, so this line is for learnings and reflections and never doubles that card.

| Reason | Line | Actions |
|---|---|---|
| `.draft` | "Zeus is waiting to deliver to your assistant: unsent text in Terminal · Open in Terminal · Don't send" | Open in Terminal; "Don't send" is the existing cancellation path (`respondToDraftCancellation`) and asks first. It is not called "Deliver anyway": Zeus never clears or submits the user's draft, so there is no way to deliver past it |
| `.busy` | "Zeus is waiting to deliver to your assistant: it's been busy for 12 min · Open in Terminal" | the minutes update in place, at most once a minute; past an hour "1 h 5 min" |
| `.disconnected` | "Zeus is waiting to deliver to your assistant: it isn't connected · Start Assistant" | "Start Assistant" only when Zeus runs the assistant and it's off; otherwise no action |
| `.olderSetup` | none of its own: the stale-setup line below is the notice | |

**Stale setup** (`managedSetupStale`), one line per conversation nonce like the UP1 update line, never while a question is pending:

| State | Line | Settings › Assistant |
|---|---|---|
| tools and template | "Zeus has new tools and instructions for your assistant · Restart assistant" | status box "Zeus has new tools and instructions for Claude Code. Restart to use them; the conversation is kept." with the Restart button |
| tools only | "Zeus has new tools for your assistant · Restart assistant" | "Zeus has new tools for Claude Code. Restart to use them; the conversation is kept." |
| template only | "Zeus has new instructions for your assistant · Restart assistant" | "Zeus has new instructions for Claude Code. Restart to use them; the conversation is kept." |
| after pressing | "Restarting when Claude is idle…" (the UP1 text, `agentUpdateWaitingText`) | same |
| `templateEdited` | "Your assistant's instructions are older than Zeus's template · Open Folder · Use the new template" | status note "Your assistant's instructions are older than Zeus's template. Open the folder to compare, or use the new template." with "Open Folder" and "Use the new template…" buttons (ellipsis: it always asks first, like "Delete This Day…") |

The thread line says "Restart assistant" (sentence case, as the UP1 line does); buttons in Settings and the menu say "Restart Assistant" (`ZeusManagedCopy`). The agent's name comes from `agentName`; "Claude Code" above is the example.

**"Use the new template"** asks first, in the Settings sheet style (Replace / Cancel, as for imports):
- Title: "Replace your edits?"
- Body: "Using the new templates replaces AGENTS.md and CLAUDE.md in your assistant folder, including your edits. Everything else in the folder stays. Your assistant restarts to read them." (Replace restores both files from the shipped snapshot, so the body names both and never claims which one differs.)
- Buttons: "Replace" (confirms), "Cancel". After Replace the restart follows the stale-setup path above.

**Menu.** While a hold is older than 10 minutes the status line under the assistant reads "Waiting to deliver to Claude" (the agent's short name). The draft case keeps the existing "Waiting on unsent text in Terminal", which already says why.

## 7. Drop on Zeus

> **Phase A: ships in Phase A.**

- **While dragging over the avatar:** the avatar shows its `alert` state, and a peek-style label reads "Drop to attach". Nothing else changes.
- **After the drop:** the panel opens with the composer focused and the items as removable chips above the text field. Chips use the existing attachment chip, with the file name or "Text" or "Image" or the URL's host.
  - Send works with no text.
- **A folder** also adds a chip action "Work in this folder" (managed session only). It goes through the existing S3 folder-change confirmation.
- **Nothing dropped is journalled.** It's sent only when you press Send, like any attachment.

## 8. First run and welcome

> **Phase A: ships in Phase A.**

- The welcome and first-run copy say nothing about levels 2–4 until one is on (LM2-A §5).
- The status strip doesn't change.
- The Talk shortcut hint (KR1) is unaffected.

## 9. Level 3 · "Screen" (Phase B)

> **Phase B: shipped (LM2-B-A).**

Pipeline and costs: `docs/research/on-device-vision.md`. Renders: `scripts/design-harness/render.sh "screenMockups()"` → `docs/design/lm2/lm2b-*.png`.

**Pictures (PM decision, LM2-D2):**
- Every picture region in the frame larger than 48×48 px is pixellated by default.
- Whole-frame face detection runs as a cheap extra. There's no tiling at capture time.
- The copy says "pictures and faces are pixellated" (R7: aligned with `FrameRedactor`, which pixellates both; the earlier "blurred" wording is retired).

### 9.1 The level section in Settings › Privacy

```
Screen                                                        [settingsHeading]
[ ] Let Zeus look at the window in front now and then           [switch]
Zeus takes a picture of the window in front at sensible moments, covers
private text and pixellates pictures on this Mac, and keeps a one-line description
of what you were doing. Never the whole screen.                [caption]

Record in   ( Everywhere except my private list | Only in apps I choose )
<list, §3>
Up to       ( 4 an hour | 12 an hour | 30 an hour )            [SettingsSegments, default 12]
Pictures that look the same as the last one don't count.       [caption]
Keep descriptions for   ( 7 days | 30 days | 90 days )        [default 90]
Pictures are deleted after 7 days.                             [caption]
```

- **Apple Intelligence off:** add the caption "Apple Intelligence is off, so Zeus writes simpler descriptions." (CONTRACT §13: the `NLTagger` fallback still writes a description)
- **Battery:** in Low Power Mode or below 30 % battery, Zeus still takes pictures but writes their descriptions later. There's no copy for this; it's invisible.

**Safari in Level 3's allow list:** a caption under Safari's row reads "Private windows can't be told apart, so their pictures and descriptions are kept too." Level 2's caption is unchanged.

### 9.2 When Zeus looks ("smart timing")

This paragraph is used in the consent sheet and in SETUP.md:

> Zeus doesn't record your screen. It takes one picture of the window in front when something has changed: after you've switched to an app or document and stayed for 10 seconds, every 5 minutes if you stay in the same place, when you come back from a break, and when you ask. It skips the picture if the window looks the same as last time. It never takes one during a video call, while your screen is mirrored for a presentation, while a password field is active, or in private windows and apps on your private list.

### 9.3 Consent sheet, Level 3 (one time)

- **Title:** "Screen"
- **Body:** "Zeus takes a picture of the window in front at sensible moments, so your assistant knows what you were looking at. Before anything is kept, Zeus covers private text and pixellates pictures and faces, here on this Mac."
- **"Zeus keeps"**
  - "A picture of the window in front, with private text covered and pictures pixellated, for 7 days"
  - "A one-line description of what you were doing, for 90 days"
- **"Zeus never keeps"**
  - "The rest of your screen or other windows"
  - "Anything during a video call or while presenting"
  - "Anything while a password field is active"
  - "Private windows and apps on your private list"
  - "Sound"
- **"When Zeus looks"**: the §9.2 paragraph.
- **"An example of what's kept"**: a 360×225 mock window in the field chrome.
  - It shows a browser page with two text lines covered by solid `fieldBorder` boxes with a 1-px `outline`, and a pixellated portrait. VoiceOver: "Example covered Safari window, two private text areas covered and a picture pixellated".
  - Under it, monospaced: "10:12  Safari  Reviewing account information."
  - Caption: "Grey boxes are text Zeus covered. Pictures and faces are pixellated. The picture is kept for 7 days, the description for 90."
- **Safari** (caption, PM decision: same exception as Level 2): "Safari: Zeus takes no pictures of Safari unless you add it under Only in apps I choose. Zeus can't tell Safari's private windows apart, so those would be pictured too."
- **Caveat** (caption, LF1 wording): "Covered pictures and their descriptions go into your assistant's folder, and descriptions into summaries. Where that goes depends on the assistant you chose."
- **Permission** (caption): "Next, macOS asks you to allow Zeus under Screen Recording. Zeus uses it only for these pictures."
- **Buttons:** "Not Now" and "Continue".

### 9.4 Screen Recording permission flow

1. **Continue** turns the level on and asks macOS once. Until it's granted, a caption line shows under the switch: "Waiting for Screen Recording permission. · Open System Settings".
2. **macOS needs Zeus to reopen** after granting: "Allowed. Reopen Zeus to start taking pictures. · Reopen Zeus". The link relaunches Zeus and keeps the conversation.
3. **Revoked later:** "Screen Recording is off for Zeus, so no pictures are taken. · Open System Settings". The level stays on and resumes when it's allowed again.
4. **A standing caption** under the switch while the level is on: "macOS may show its screen-recording indicator for a moment when Zeus takes a picture, and may ask now and then whether Zeus can still see your screen." The indicator is macOS's own and isn't hidden or imitated.
5. **Paused:** while a hard stop holds, the level's caption reads "Paused: a video call is on" / "Paused: presenting" / "Paused: a password field is active". It reverts to the normal caption when the stop clears. There's nothing in the thread.

### 9.5 Pictures in What Zeus Kept

**Rows:** a picture item's row starts with a 96×60 thumbnail (the covered frame, 1-px `outline`), followed by the description as stored.
- Caption under the description: "Picture · 6 days left".
- If the picture was dropped or has expired, the thumbnail slot shows a `field` box with "No picture", and the caption gives the reason:
  - "Picture not kept: it looked private" (the model's flag)
  - "Picture deleted after 7 days"
  - "Picture deleted by you"

**Detail window:** clicking a thumbnail (or Return on a focused row) opens a sheet titled "Picture from 10:12".
- **Left:** the frame, fitted.
  - Every covered area is outlined with a 1-px `focusRing` rectangle.
  - Legend under it (caption): "▭ Covered text · ▭ Pixellated picture", with counts: "3 covered · 1 pixellated".
- **Right column:**
  - App
  - Window, as stored, with placeholders visible
  - Description
  - "Kept until Mon 19 Oct"
- **Buttons:**
  - "Delete Picture" keeps the description. No confirmation, and it shows the Undo toast.
  - "Delete Both" asks: "Delete this picture and its description? This can't be undone."
  - "Close".
- **Keys:** ← and → go to the previous or next picture that day, Escape closes, and ⌘⌫ is Delete Picture.
- **VoiceOver:** the image is one element, "Picture of <app>, <n> areas covered". The description is read next.

**Filters:** Level 3 joins the Level filter as "Screen".

### 9.6 "Ask about this": context chips in the composer

**Talk shortcut caption** (General › Talk shortcut), the second sentence:
- Normally: "Add ⇧ (⇧⌥⌘Z) to ask about the window in front."
- If the Talk shortcut already uses ⇧, there's no second shortcut and the sentence reads: "Ask About This is in the Zeus menu, because your shortcut already uses ⇧."
- With the shortcut off, there's no second sentence.

- **How to open it:**
  - The menu item "Ask About This" (Zeus menu, below "Talk to Zeus…").
  - The Talk shortcut with Shift added (⇧⌥⌘Z by default; the shortcut's caption says so).
- **What it does:** it opens the conversation with chips for what's in front, already attached and removable.
- **One chip per capture.** A chip appears only when its level is on and the capture worked:

  | Chip | Label | Needs |
  |---|---|---|
  | Window | "Window · ManagedSessionController.swift" | Level 2 |
  | Selection | "Selection · 42 words" | Level 2 (the front app's selected text via Accessibility) |
  | Page | "Page · docs.example.com" | Level 2 and a browser that reports private windows |
  | Picture | 32×20 thumbnail + "Picture · Xcode" | Level 3 |

- **Chips are attachment chips** (§7), each with an × button. VoiceOver: "Remove Window".
  - Hovering a chip shows its exact redacted content (the title, the selected text, the URL, or the covered picture).
- **Caption above the chips:** "From the window in front, with private details removed. Remove anything you don't want to send."
- **With no level on:** "Ask About This" still opens the conversation, with the caption "Turn on Windows and pages or Screen in Settings › Privacy to attach what's in front."
- **Sent chips** go to the "Sent to your assistant" ledger as "Attached: Window, Picture" on the message's row.
- **A hard stop at that moment** (password field, private window): the affected chips don't appear, and the caption adds "Some things weren't attached because they're private."

## 10. Level 4 · "Typing" (Phase C)

> **Phase C: shipped (LM2-C-A).**

Pipeline, costs and the reasons behind these choices: `docs/research/on-device-keystrokes.md`. Renders: `scripts/design-harness/render.sh "typingMockups()"` → `docs/design/lm2/lm2c-*.png`.

**What's kept:**
- A one-line **topic** per stretch of typing, for 30 days.
- The **words**, with private details removed, for 24 hours by default.
- Level 4 needs Apple Intelligence, because the on-device model is what catches names and numbers in casual typing.

### 10.1 The level section in Settings › Privacy

```
Typing                                                        [settingsHeading]
[ ] Let Zeus keep what I type in apps I choose                 [switch]
Zeus notes what you were typing about, like "replying to a doctor about
rescheduling", so your assistant can help with it. Only in the apps you
choose, and never in password fields.                          [caption]

Record in   Only in apps I choose                              [label settingsBody, value settingsCaption: not a choice]
<allow list, §3: rows with icon, name, "–"; "Add App…">
No apps chosen yet, so nothing is recorded.                    [empty-state caption]

Keep topics      ( 7 days | 30 days | 90 days )              [SettingsSegments, default 30 days]
Keep the words   ( Don't keep | 24 hours | 7 days )            [SettingsSegments, default 24 hours]
Topics are kept for <N> days. The words, with private details removed, are kept as you choose here.   [caption; <N> follows Keep topics]
```

- **The coin is fixed.** Level 4 has no "Everywhere" option.
  - "Record in" is shown as plain text: "Only in apps I choose".
  - Caption under the list: "Zeus never records typing in an app you haven't added."
  - The private list still wins: adding an app that's on it shows "<App> is on your private list. Remove it there first."
- **Browsers in the allow list:** typing in private windows is never kept. Safari can't tell its private windows apart (§3), so adding Safari here shows the caption "Typing in Safari's private windows can't be told apart, so it's kept too."
- **Apple Intelligence off:** the switch is disabled, with the caption "Typing needs Apple Intelligence, which removes names and numbers from what you type. Turn it on in System Settings › Apple Intelligence & Siri."
- **IME:** with a Japanese, Chinese or Korean input source active, the record reads "Typed in <App>" and has no words and no topic. There's no extra copy.

### 10.2 Consent sheet, Level 4 (one time)

- **Title:** "Typing"
- **Body:** "Zeus notes what you were typing about in the apps you choose, so your assistant knows what you're working on and can help with it. Before anything is kept, Zeus removes names, numbers, addresses and secrets, here on this Mac."
- **"Zeus keeps"**
  - "What each stretch of typing was about, for 30 days (you can change this)"
  - "The words, with private details removed, for 24 hours (you can change this, or keep no words at all)"
- **"Zeus never keeps"**
  - "Anything you type into a password field"
  - "Typing in apps you haven't chosen, or in private windows in Chrome and Edge"
  - "What you paste: Zeus only notes that you pasted"
  - "Typing made by other apps, such as a password manager filling in a form"
- **"An example"**, in the field chrome:
  ```
  14:05  Mail  hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore
         → Replying to a doctor about rescheduling an appointment
  ```
  - Caption under it: "The first line is the words as kept for 24 hours. The second is the topic kept for 30 days. Your assistant can read both while they're kept."
- **Safari** (caption, the same exception as Levels 2 and 3): "Safari: Zeus notes nothing you type in Safari unless you add it under Only in apps I choose. Zeus can't tell Safari's private windows apart, so typing in those would be kept too."
- **Caveat** (caption, LF1 wording): "Topics and the words, as kept, go into your assistant's folder, and topics into summaries. Where that goes depends on the assistant you chose."
- **Permission** (caption): "Next, macOS asks you to allow Zeus under Input Monitoring. Zeus uses it only to read keys in the apps you choose."
- **Suggestion** (caption): "If you'd rather keep no words, choose Don't keep after turning this on. Topics still work."
- **Buttons:** "Not Now" and "Continue".

### 10.3 Choosing apps first

- Turning Level 4 on with an empty allow list opens the app picker straight after the consent sheet. The panel message is "Choose the apps where Zeus may note what you type."
- Cancelling the picker leaves the level on, with the empty-state caption.

### 10.4 Input Monitoring flow

| State | Caption under the switch | Link |
|---|---|---|
| Asked, not yet allowed | "Waiting for Input Monitoring permission." | "Open System Settings" |
| Allowed, macOS needs a reopen | "Allowed. Reopen Zeus to start." | "Reopen Zeus" |
| Denied | "Input Monitoring is off for Zeus, so nothing you type is noted." | "Open System Settings" |
| Revoked while running (found by Zeus's check, at most a minute later) | the same as Denied | "Open System Settings" |
| Paused by a password field | "Paused: private input." | none |
| Paused because the front app isn't chosen | nothing (that's normal) | — |

- The level stays on through denied and revoked states and resumes by itself when permission comes back.
- Zeus asks macOS for permission only from the consent sheet, never on its own later.

### 10.5 The "Private input" indicator

While secure input is on (a password field is active) and Level 4 is on:

- **Zeus menu:** the status section shows a line "Private input: Zeus isn't noting typing". It's a disabled line, in the same place and style as "Hidden until …".
- **Settings › Privacy › Typing:** the caption reads "Paused: private input." (§10.4).
- **The avatar and the thread show nothing.** A visible cue exactly when a password is being typed would draw attention to that moment. The menu line is there for anyone who checks.
- **VoiceOver:** nothing is announced, for the same reason.
- When secure input turns off, the line goes. The run that was open when it turned on is discarded, not kept.

### 10.6 Typing in What Zeus Kept

- **Level filter:** "Typing" joins the Level filter.
- **Grouping:** typing items are grouped **by app, then by hour**:
  ```
  Mail · 14:00–15:00                                   3 stretches
    14:05  → Replying to a doctor about rescheduling an appointment
           hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore
    14:31  → Drafting a project update for a colleague
           words not kept
  ```
- **Each stretch** shows its topic first (`settingsBody`, prefixed with "→"), and below it the words exactly as stored (`settingsCaption`, monospaced, placeholders in `secondaryText`). In place of the words, the caption can read:
  - "words not kept" (Don't keep is on)
  - "words deleted after 24 hours"
  - "pasted" (for `‹pasted›` segments, shown as the placeholder)
- **The group header** gives the app, the hour range and the number of stretches. Click it to collapse; groups are expanded by default for today and collapsed for earlier days.
- **Delete:** per stretch (hover and context menu, Undo toast). Per group, use "Delete <App> 14:00–15:00", which asks "Delete what Zeus kept from your typing in <App> between 14:00 and 15:00?" Deleting removes both the topic and the words.
- **Search** matches topics and words. A match on the words shows the words even in collapsed groups.

### 10.7 Retention

- **"Keep the words"** (`SettingsSegments`): "Don't keep", "24 hours" (default), "7 days".
  - Changing it to a shorter choice deletes older words at once.
  - There's no confirmation; the caption under it changes to "Deleted words older than 24 hours."
- **"Keep topics"** (`SettingsSegments`, above Keep the words): "7 days", "30 days" (default), "90 days". This supersedes the earlier fixed 30 days (LM2-C task).
  - Shortening it deletes older topics at once, with the same caption swap: "Deleted topics older than 7 days."
  - If the choice would keep words longer than topics, nothing changes: words are always deleted on their own schedule, and a topic's words never outlive it.
- "Delete Everything…" covers both.

## 11. Phase D · depth: journal questions, acting rules, outcomes

> **Phase D: shipped (LM2-D-A).** The tools are in `AGENT_LEARNING.md` §3 and §5; the shipped tool fields are `wouldHave` / `did`.

The assistant's side of all this is `docs/design/AGENT_LEARNING.md`. Renders: `scripts/design-harness/render.sh "depthMockups()"` → `docs/design/lm2/lm2d-*.png`.

### 11.1 "Raw on request" (per level)

> **Retired by LF1 (§12):** the folder follows the enabled levels, so these switches and sheets are removed. Kept for the history of the ledger rows.

- **Which levels:** only Level 3 (pictures) and Level 4 (words) have anything rawer than what the assistant already gets.
  - Level 1 and 2 records are already the stored form, so they have no switch.
  - Even "raw" is the **stored** form: covered pictures and redacted words. It's never the original screen or keystrokes.
- **The switch:** in each level's section, after retention, a checkbox. Off by default.
  - Level 3: "Let my assistant see the pictures when it asks"
  - Level 4: "Let my assistant see the words when it asks"
  - Caption: "Otherwise it gets only descriptions. Each time it looks, you'll see a line in the conversation."
  - Level 4's caption says "topics" instead of "descriptions".
- **The sheet on first turning it on**, titled "Let your assistant see pictures?" (Level 4: "…see the words?"):
  - **Body:** "When your assistant asks about a moment, it can get the picture Zeus kept (with private text covered and pictures pixellated), not just the description. That picture goes to your assistant's model provider, like anything you send."
  - Level 4 body: "…it can get the words Zeus kept (with names, numbers and secrets removed), not just the topic. Those words go to your assistant's model provider, like anything you send."
  - **Caption:** "Every time it looks, the conversation says so, and What Zeus Kept › Sent to your assistant shows exactly what it got."
  - **Buttons:** "Cancel" and "Allow".
- **Turning it off** takes effect at once. There's no sheet.

### 11.2 The journal-answer line

When the assistant calls `zeus_get_journal`, the thread gets a quiet notice line (§6 style): no peek, no sound, not unread.

| Case | Line |
|---|---|
| Descriptions, titles and topics only | "Looked at your journal: Tue 14:00–15:30 · View" |
| | "View" opens Sent to your assistant at that answer's row (the sent-answer callback), never a journal date range. |
| It also got pictures or words | "Looked at your journal, including 2 pictures: Tue 14:00–15:30 · View" (or "including your words") |
| It asked for raw and was refused | "Looked at your journal: Tue 14:00–15:30 (descriptions only) · View" |
| Nothing matched | "Looked at your journal: nothing for Tue 14:00–15:30" (no action) |

- **View** opens What Zeus Kept › Sent to your assistant at that answer.
- **Several looks in 10 minutes** collapse to one line: "Looked at your journal 3 times · View".

### 11.3 Ledger rows for journal answers

A new kind in Sent to your assistant: "Journal answer". The row reads "▸ 14:32  Journal answer  ■ Claude · Zeus  … 3 items".
- Expanding it shows the range, the query in quotes if there was one, and each item exactly as sent. Pictures show as thumbnails, and clicking one opens the picture detail (§9.5).
- A refused raw request reads "Asked for pictures; not allowed".

### 11.4 Lines for acting rules

The shadow line first. Two plain actions once the thread line supports a second one (ST1 added `ThreadNotice.secondaryTitle`): "OK next time?" and "Not this". Until then, one action, with "Not This" in Settings › Rules (§6). The verb follows what the rule would have done:

| Verb | Shadow line |
|---|---|
| sent | "I'd have sent “Running late, 10 min” to the team chat · OK next time?" |
| posted | "I'd have posted the weekly summary to the project channel · OK next time?" |
| drafted | "I'd have drafted a reply to the scheduling email · OK next time?" |
| changed | "I'd have moved your 15:00 meeting to 15:30 · OK next time?" |
| bought | "I'd have bought the usual coffee beans for €14 · OK next time?" |
| booked | "I'd have booked the 8:10 train to the office · OK next time?" |

- After **OK:** "OK. I'll do that from now on. · Undo". Undo puts the rule back in shadow.
- After **Not this:** the line resolves to "Got it. I won't." with no action. The rule retires (PM decision for Phase D; the core's `declineRule`), and no separate "Retired …" line is posted for it.
- **The acted line** appears once a rule is active and the assistant has acted, as a quiet line:
  - **Shipped wording (PM task, LM2-D):** "Did: ‹what the assistant reported› · Undo" (or "· Not again" when it can't be undone). The verb forms below are the target once the tools carry a verb; see `review-lm2-bcd.md` P1.
  - Reversible: "Sent “Running late, 10 min” to the team chat · Undo"
  - Not reversible: "Sent “Running late, 10 min” to the team chat · Not again"
  - After Undo: "Undoing…", then the assistant's own one-line reply ("Done: message deleted." / "Couldn't unsend it; it was delivered.").
  - After Not again: "Rule turned off · Review".
- **Spending** (`bought`, `booked`) always shows the amount in the line ("for €14"). An amount above the rule's or the last time's arrives as a normal question (`zeus_ask`), not a line.
- **The rule name** shows on hover over every acting-rule line ("Your rule: Tell the team chat when I'm late for stand-up").

### 11.5 "Rule retired" lines

| Why | Line |
|---|---|
| Kept skipping or undoing | "Retired a rule you kept skipping: “Prepare PR list at 8:50” · Review" |
| Turned off | "Retired a rule you turned off: “…” · Review" (only for agent rules the user toggled off twice) |
| Never applied (the stale signal, §7 of AGENT_LEARNING.md) | "Retired a rule that never applied: “…” · Review" |

- **Review** opens Settings › Rules › Retired at that rule.
- **Retired rows** show the same reason ("Retired 14 Oct: you kept skipping it") and "Turn Back On".

### 11.6 "Why?" with outcomes

The Why? popover (§5.3) gains a second part.

```
Why this rule
Based on:
  Mon 12 Oct · 18:20 · Slack · #design-review …
  Tue 13 Oct · 18:42 · Slack · #general …
Proposed by your assistant on Wed 14 Oct

What happened since
  ✓ Wed 15 Oct 18:05 · Accepted · held messages read
  ↶ Thu 16 Oct 18:30 · Undone · you pressed Show
  – Fri 17 Oct · Ignored · prepared list unopened
  ✕ Sat 18 Oct · Skipped · its question
Fairly sure
```

**Spending rules** (PM decision, LM2-D task): the row shows "Always asks" in place of the confidence meter and word ("Always asks · from your assistant · 3 days ago"); Why? ends with "Always asks · <confidence word>".

The core records each outcome as a category, a source, a date and a confidence change, with no prose and no history of the confidence word. So each entry is `<glyph> <date> · <Label> · <source>`, where the source is the event's category in plain words (held messages read, you pressed Show, prepared list unopened, its question, turned off in Settings, …). The change in confidence is never shown as a number, and the last line is only the current word.

- Glyphs are pixel-drawn, not font glyphs (the pixel font lacks them): `ZeusGlyph` check (accepted), reply (undone), close (skipped); a drawn dash (ignored, never applied); drawn 6-pt circles, filled (turned on) and outlined (turned off); a small app-drawn pencil (edited). They are decorative (`accessibilityHidden`); the label word carries the meaning and VoiceOver reads it.
- Newest first, at most 10 entries, then "and 6 earlier".
- The last line is the current confidence word only. It's never a number, and there's no "was …" history.
- With no outcomes yet: "Nothing has happened with this rule yet."

## 12. LF1 · The assistant folder is the record

> **Status: building (LF1-P writes the folder, LF1-A the settings; copy here is final).** User decision 2026-10-15: everything Zeus keeps is written, after the safeguards, into the assistant's folder, accumulating whether or not it was sent. Where that folder lives, synced or not, is the user's choice, and Zeus never warns about it.

### 12.1 What the folder holds

`<assistant folder>/Zeus/`, written by Zeus from the journal: `README.md`, `days/<yyyy-mm-dd>/` (`activity.md`, `focus.md`, `screen/<HHmmss>-<app>.jpg` + `.md`, `typing.md`, `summary.md`, `moments.md`), `reflections/<yyyy-mm-dd>.md`, `rules.md`, `preferences.md` (§13). Content is exactly what the journal stores, redacted and covered; the per-level "Raw on request" switches (§11.1) are retired, and `zeus_get_journal` follows the levels too. Retention pruning and every delete remove the matching files (Undo restores them). A file the user deleted in Finder is not re-created. Zeus never touches anything else in the folder, including the assistant's own `Notes/`. **Zeus only replaces or deletes files it wrote itself (FX5).** Its record of what it wrote is the only authority: Delete Everything removes those files, any temp files Zeus left behind, and then only the empty directories Zeus created, `Zeus/` itself last and only if it's empty. A file already at a path Zeus wants to write, that Zeus didn't write, is adopted when its bytes are what Zeus would write (this recovers a lost record) and otherwise left alone, skipped and reported in the folder row (§12.2) until it's moved.

`Zeus/README.md` opens with: "Zeus writes this folder. It holds what Zeus learned about how you use your Mac, with private details already removed. Zeus overwrites and prunes these files; don't edit them. Delete a file and it stays deleted. Zeus only replaces or deletes files it wrote itself; anything else in this folder is left alone."

### 12.2 The folder row (Settings › Privacy, top of the pane under the caption)

Label **"Your assistant's folder"**, then one line and actions by state:

| State | Line | Actions |
|---|---|---|
| Zeus runs the assistant | "Kept in ~/Zeus Assistant/Zeus" (path abbreviated with ~) | "Show in Finder" |
| Zeus runs the assistant, no folder yet | "Not kept in a folder yet. Choose your assistant's folder under Assistant." | "Assistant Settings" (switches to that tab; no ellipsis, it opens no window) |
| Connect your own, folder chosen | "Kept in ~/Assistant/Zeus" | "Show in Finder", "Choose…", "Stop keeping a folder" |
| Connect your own, none | "Not kept in a folder. Choose one and Zeus writes what it keeps there for your assistant." | "Choose…" |
| Write failed (any state) | the line above and its buttons, then a second line in `settingsError` colour with the writer's own message (`lastWriteError`), with no button of its own: the row's buttons already offer the next step. "Zeus can't write to this folder." for a failed write. For a collision with a file Zeus didn't write (§12.1): "Zeus didn't replace Zeus/README.md because it isn't a file Zeus wrote. Move or rename it to let Zeus write there." and for several: "Zeus didn't replace Zeus/README.md and 2 other files because Zeus didn't write them. Move or rename them to let Zeus write there." Paths are relative to the assistant folder. The line goes away on the next export once the file has moved. | |

- Caption under the row: "Where this folder lives is up to you. If it syncs, what Zeus keeps syncs with it."
- "Stop keeping a folder" asks nothing and leaves the folder's files alone; the line becomes the none state.
- Settings › Assistant, under the folder picker: "Zeus keeps what it learns in Zeus/ inside this folder, and your assistant keeps its notes in Notes/."
- VoiceOver: "Your assistant's folder, kept in ~/Zeus Assistant/Zeus", then the buttons' own labels.

### 12.3 "Cover pictures and faces" (Screen level section, after retention)

- **Checkbox:** "Cover pictures and faces". On by default. Caption while on: "Private text is covered and pictures and faces are pixellated before a screenshot is kept." While off: "Screenshots are kept as they are. Passwords, keys, card and account numbers and ID numbers are still covered."
- **Turning it off** shows a sheet first:
  - **Title:** "Keep pictures uncovered?"
  - **Body:** "Zeus will keep screenshots as they are, with pictures, faces and text uncovered. Passwords, keys, card and account numbers and ID numbers are still covered, and Zeus still never takes a picture of a password dialog, a private window or an app on your private list. Pictures already kept stay covered."
  - **Buttons:** "Keep Covering" (default, Escape) and "Turn Off".
- **Turning it on** needs no sheet and applies to new pictures only.
- With the box off, the level caption (§9.1) drops its covering clause: "Zeus takes a picture of the window in front at sensible moments and keeps a one-line description of what you were doing. Never the whole screen." The consent sheet example is unchanged, and the §9.1 "Zeus keeps" row reads "The picture of the window in front, as it is, for 7 days".
- VoiceOver: "Cover pictures and faces", value On/Off; the sheet's title is its accessibility label.

### 12.4 The Privacy caption and the per-level caveats

- The pane caption (`PrivacySettingsView.caveat`) becomes: "Zeus never sends your data anywhere itself. Your assistant reads its folder and what Zeus sends it. Where that goes depends on the assistant you chose."
- Level caveats follow the same shape (replace §2.2, §9.1 and §10.1's lines and the code they describe):
  - Level 2: "The records go into your assistant's folder, and summaries of them go to your assistant like any message. Where that goes depends on the assistant you chose."
  - Level 3: "Covered pictures and their descriptions go into your assistant's folder, and descriptions into summaries. Where that goes depends on the assistant you chose."
  - Level 4: "Topics and the words, as kept, go into your assistant's folder, and topics into summaries. Where that goes depends on the assistant you chose."
- Principle 1 (§1) now reads: "Nothing leaves your Mac by Zeus's hand. What Zeus keeps goes into your assistant's folder after the safeguards; your assistant decides what it reads and where it sends it."

### 12.5 What Zeus Kept

- Header under the segments: "Kept in ~/Zeus Assistant/Zeus" with "Show in Finder" (hidden when no folder is kept).
- Each row gets "Show in Finder" beside "Delete" (hover and context menu; VoiceOver custom action "Show in Finder"). It selects the item's file; a missing file (deleted in Finder) shows the day folder instead. The footer button for the day is "Show Day in Finder", so it can't be confused with the header's folder button.
- The Raw on request switches and their sheets are removed from the Screen and Typing sections. `JournalAnswerDisplay.rawCaption` stays for old ledger rows.

### 12.6 Delete Everything

- The confirmation reads (FX5): title "Delete everything Zeus kept and sent?", body "This removes what Zeus kept here and the files Zeus wrote in Zeus/ inside your assistant's folder. Anything else in that folder stays. This can't be undone." It promises only Zeus's own files, because that is all Delete Everything removes (§12.1).
- A checkbox under it, off by default: "Also delete your assistant's notes", caption "Everything in its Notes folder is deleted, including files you or your assistant put there." Passed as `includeAssistantNotes`. The caption says what the checkbox really does: Notes/ is emptied whole, not by Zeus's record.
- Buttons unchanged: "Cancel" (default) and "Delete" (destructive).

## 13. FB1 · Ratings

> **Status: shipped (0.2.7).** User decision 2026-10-16; this section was brought in line with the merged code on 2026-10-16 (FB1-D2). The surfaces (the ⋯ glyph, the row, muted rows, Settings "What you hear about", the suggestion line) are in `CONVERSATION.md` §17; this section is what is kept, sent and written. Ratings work with every learning level off.

### 13.1 What is kept

A rating is one record on this Mac, encrypted like the rules: the kind label (editable), its normalized key, the choice (More like this / Neutral / Stop these), the scope (the kind, or this message only), the example card and its text as already redacted, and when it was made and last changed. Alongside the ratings Zeus keeps, in the same store:

- **Hold decisions:** for each card held under a "Stop these" rating, which rating matched, how ("Same label", or the on-device similarity score against the threshold), when it was decided, and when it was released by "Not this kind". A released card keeps its decision as history.
- **Quiet signals:** when an unprompted card was first shown, opened and dismissed, per kind, for the suggestion line only. Nothing is inferred into a rating: a suggestion is a line the user can ignore, never an automatic mute.
- **One Undo snapshot:** the preferences as they were before the latest change, valid until the next change (CONVERSATION.md §17.2).

**How holds are decided.** A new unprompted card whose `about` matches a rated kind's label exactly follows that rating. Otherwise, for each "Stop these" kind, Zeus compares the card's label and text with the rating's label and example using the on-device NaturalLanguage sentence embeddings; a score at or above the threshold holds the card. If no embedding is installed for the card's language, only exact label matches hold, and look-alikes get through. Replies are never compared or held.

**Changing or removing a rating does not touch cards already held.** Changing "Stop these" to another choice, removing the rating, or undoing it stops new holds; cards held before stay in their muted rows until the user picks "Not this kind" on each (which releases only that card) or clears the conversation. Delete Everything releases them all (§13.4).

### 13.2 What is sent, and the folder

- Each rating, change, removal, Undo and "Not this kind" correction goes to the assistant as a delivery, acked like a summary. A rating reads "Rating: Stop these · kind: On-call reminder · scope: kind · example: “…”." followed by one sentence on how to apply it (kind: "Apply this to the kind, including similar messages with different labels. Neutral uses your judgment. Replies to user input are unaffected."; just this one: "Feedback on this message only; do not create a kind rule."). The three choices are sent as "More like this", "Need-to-know" and "Stop these". A removal reads "Rating removed · kind: …"; an Undo sends the current preferences in full; a correction reads "Rating match corrected: the held message was not this kind: …". The example is the redacted text; emoji in the delivery is fine, it's not rendered in the pixel font. Nothing is said in the thread for the delivery itself: the bubble's own line ("Stopped: On-call reminders") is the record, and the ledger has the exact text.
- `Zeus/preferences.md` in the assistant's folder lists every kind rating under "Up", "Need-to-know" and "Stop", each with its label and redacted example, after a short note on what the three mean. It is rewritten on every change. Ratings of this message only are not in it: they are delivered once and never become a kind. The delivery's `Files:` line names the file when it exists. It is part of `Zeus/` like everything else in §12: Zeus writes and prunes it, and the user may delete it; a file removed in Finder is not re-created and the ratings themselves are unchanged.
- Current kind ratings are an input to the evening reflection, as the rules are.

### 13.3 What Zeus Kept

- **Sent to your assistant:** one row per rating delivery once the assistant has acknowledged or read it, with the summary "Sent your message preference" (every rating kind: new, changed, removed, undone and corrected). View shows the delivery text as sent. Until then the delivery is a Waiting row (§4.2). There is no conversation notice for a rating receipt.
- **Kept on this Mac:** nothing of its own. Ratings, hold decisions and quiet signals are reviewed and changed in Settings › Rules › What you hear about (CONVERSATION.md §17.4), which lists kind ratings only; a rating of this message only is visible as the bubble's line and its Sent row. Muted cards stay ordinary cards, shown as they are.

### 13.4 Delete Everything

"Everything" includes the ratings, hold decisions, quiet signals, Undo snapshot and any rating deliveries still waiting, and `Zeus/preferences.md` in the folder; every held card is released, back to an ordinary bubble. The confirmation text in §12.6 is unchanged. Clear Conversation removes muted cards like any other card and leaves the ratings alone.
