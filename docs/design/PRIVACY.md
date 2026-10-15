# Privacy surfaces: Learn from me, the journal and rules

The spec for everything the user sees about what Zeus observes, keeps, sends and decides (LM2 Phase A, levels 1–2, rules).
Copy in quotes is final unless the code needs to shorten it, in which case ask the designer.
Settings uses the system font and the existing Settings components (`settingsTitle`, `settingsBody`, `settingsCaption`, `settingsError`, `SettingsSegments`, `KeyboardButton`, `SettingsDivider`). There are no new ZeusDesign tokens.
Renders: `scripts/design-harness/render.sh "privacyMockups()"` → `build/q2-renders/lm2-*.png`, copied to `docs/design/lm2/`.

## 1. The seven principles

These are the README promise. Every surface below exists to keep one of them visible.

1. **Raw observation never leaves your Mac.** Your assistant gets summaries, rules and, when it asks, a redacted excerpt.
2. **Private details are removed before anything is stored**, not just before it's sent. Nothing goes to disk unredacted.
3. **Every level is its own switch, off by default.** Turning one on shows exactly what it keeps, with an example record.
4. **Some things are never recorded:** password fields (secure input), private browser windows, apps on your private list, and a locked screen.
5. **You can see everything Zeus kept and everything it sent**, exactly as stored and as sent.
6. **Delete is immediate and complete:** one item, a day, an app, or everything.
7. **Summaries go to your assistant's model provider**, like any message you send. The consent sheets say so.

## 2. Settings › Privacy

Top to bottom:

1. **Status line** (caption). Shown only when at least one level is on. Exact wording:
   - Apple Intelligence on: "Private details are removed on this Mac before anything is kept."
   - Apple Intelligence off: "Private details are removed on this Mac before anything is kept. Apple Intelligence is off, so only fixed patterns (emails, card numbers, passwords…) are caught."
2. **Level 1 · "Apps and timing"**: the existing L1 section (switch "Let Zeus learn when and in what I work", private list, notes, retention). Its title changes from "Learn from me" to "Apps and timing", and the pane's first title is now "Learn from me" above all levels.
3. **Level 2 · "Windows and pages"**: §2.1.
4. **What Zeus kept**: §4.
5. **Pause for Today / Delete Everything…**: unchanged. "Delete Everything…" now covers the whole journal.

Levels 3 ("Screen") and 4 ("Typing") don't appear until they're built. There are no "coming soon" rows.

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
  - "Private browser windows"
  - "Apps on your private list"
- **"An example of what's stored"**: a monospaced block in the field chrome. The synthetic record shows two redactions:
  ```
  09:41  Mail     Subject: Lunch with ‹name› on Friday
  09:44  Chrome   Q3 planning – Docs · docs.example.com/d/‹id›
  09:52  Xcode    ManagedSessionController.swift — Zeus
  ```
  - Caption under it: "Names, emails, numbers and other private details become placeholders like ‹name› before anything is stored."
- **Safari line** (caption): "Safari: Zeus keeps only that you used Safari, because it can't tell private windows apart." Drop this line if appdev finds a reliable positive check.
- **Caveat** (caption): "Summaries of this go to your assistant, which sends them to its model provider like any message. The records themselves stay on this Mac."
- **Permission** (caption): "Next, macOS asks you to allow Zeus under Accessibility. Zeus uses it only to read window titles."
- **Buttons:** "Not Now" (cancel, Escape) and "Continue" (default).
  - Continue turns the level on and starts the permission flow (§2.3).

### 2.3 Permission flow (Accessibility)

1. After Continue, Zeus calls the system prompt once. If it isn't granted yet, a caption line shows under the switch: "Waiting for Accessibility permission. · Open System Settings". The link opens Privacy & Security › Accessibility.
2. Once granted, the line goes. No sheet, no sound.
3. If it's revoked later: "Accessibility is off for Zeus, so window titles aren't kept. · Open System Settings". The level stays on, and nothing is recorded at Level 2 until it's granted again. Level 1 keeps working.
4. The thread never mentions permissions. This lives in Settings only.

### 2.4 Drafts for later levels (not built in Phase A)

- **Level 3, "Screen":**
  - Switch: "Let Zeus look at my screen now and then"
  - Keeps: "A picture of the window in front, after you switch to it, every 5 minutes in the same place, and when you ask"
  - Description line: "a one-line description made on this Mac"
  - Never: "Faces (blurred), password dialogs, Keychain and banking apps, video calls, presentations, private windows"
  - Example record: "10:12 · Xcode · Writing code for a session controller; a test is failing. [picture, 7 days]"
- **Level 4, "Typing":**
  - Switch: "Let Zeus keep what I type in apps I choose"
  - The coin is fixed to "Only in apps I choose", with no "Everywhere" option.
  - Never: "Password fields, apps you haven't chosen, private windows"

## 3. The coin and the lists

`SettingsSegments` labelled "Record in", with two choices:

**1. "Everywhere except my private list"** (default)
- The list below is the **one private list**, shared by every level. It's the same list as Level 1, and editing it here edits it there.
- Caption: "Apps on your private list are never recorded at any level. Time in them counts only as private."

**2. "Only in apps I choose"**
- The list below is this level's own **allow list**. The private list still wins.
- Caption: "Zeus records this level only in these apps."
- Empty state (caption): "No apps chosen yet, so nothing is recorded at this level."

**List rows** (both lists):
- App icon (16 pt), the app name in `settingsBody`, and a trailing "–" `KeyboardButton`.
  - VoiceOver label for the "–" button: "Remove <App>"
- Under the list:
  - "Add App…" opens an open panel on /Applications. The panel message is "Choose an app to keep private." or "Choose an app Zeus may record."
  - Result line, existing L1 wording: "Added <App> to your private list." or "Added <App>."

## 4. What Zeus kept (viewer)

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

- **Rows** (newest first), in four kinds:
  - "Morning summary"
  - "Day reflection"
  - "Note"
  - "Answer to “<question>”" (Phase D)
- **Each row shows:** time · kind · session label ("■ Claude · Zeus") · size ("212 words").
  - Click to expand the exact text that was sent, read-only and selectable.
- **Caption at the top:** "Everything Zeus sent your assistant about you. Your assistant's model provider received these like any message."
- **No delete here:** the ledger records what has already been sent. Clearing it is part of "Delete Everything…".

## 5. Settings › Rules (new tab)

- **Tab:** title "Rules", SF Symbol `list.bullet.rectangle`.
- **Placement:** the tab sits after Privacy, and it's hidden until Learn from me is on at any level or a rule exists.

### 5.1 The dial

`SettingsSegments` labelled "New rules", with three stops stored as 0, 0.5 and 1. The default is the middle one (0.5). The caption under it changes with the choice.

| Stop | Caption |
|---|---|
| "Ask me first" | "Every new rule waits in Suggested until you turn it on." |
| "Balanced" (default) | "Rules about timing and tone start at once. Rules that act for you show what they'd have done once, and wait for your OK." |
| "Just do it" | "Rules start at once. Rules that act for you still show what they'd have done the first time, then act without asking. Undo is always there." |

Rules that send, post or spend never skip their first "I'd have…" line, at any stop.

### 5.2 Sections

Each section is a `settingsTitle` with a count. Empty sections are hidden, except Active.

| Section | Holds | Row extras |
|---|---|---|
| "Active" | status active | toggle (on) |
| "Waiting for your OK" | shadow | "Seen once: <what it would have done>" caption, buttons "OK" and "Not This" |
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

These are system lines in the thread: the existing notice style, the same as "Claude Code has an update · Restart assistant". There's no peek and no sound, and each line names the rule.

| Moment | Line | Actions |
|---|---|---|
| A passive rule starts | "New rule: Hold Slack messages after 18:00 · Review" | Review opens Settings › Rules at that rule |
| A rule that acts, first time (shadow) | "I'd have sent “Running late, 10 min” to the team chat · OK next time?" | One action, "OK next time?" → "OK. I'll do that from now on. · Undo". "Not This" is in Settings › Rules. Ignoring the line leaves the rule waiting, and after 24 h it counts as an ignored result |
| Zeus held messages for a rule | "Held 2 messages for your rule “No interruptions while tests fail” · Show" | Show opens the panel at the first held card |
| A rule retired itself | "Retired a rule you kept skipping: “Prepare PR list at 8:50” · Review" | Review |

- Several new rules from one reflection collapse to one line: "3 new rules · Review".
- Everything quoted inside a line has already been through the Redactor.

## 7. Drop on Zeus

- **While dragging over the avatar:** the avatar shows its `alert` state, and a peek-style label reads "Drop to attach". Nothing else changes.
- **After the drop:** the panel opens with the composer focused and the items as removable chips above the text field. Chips use the existing attachment chip, with the file name or "Text" or "Image" or the URL's host.
  - Send works with no text.
- **A folder** also adds a chip action "Work in this folder" (managed session only). It goes through the existing S3 folder-change confirmation.
- **Nothing dropped is journalled.** It's sent only when you press Send, like any attachment.

## 8. First run and welcome

- The welcome and first-run copy say nothing about levels 2–4 until one is on (LM2-A §5).
- The status strip doesn't change.
- The Talk shortcut hint (KR1) is unaffected.
