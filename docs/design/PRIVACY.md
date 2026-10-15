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

- **Level 3, "Screen":** specified in §9 (Phase B).
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

## 9. Level 3 · "Screen" (Phase B)

Pipeline and costs: `docs/research/on-device-vision.md`. Renders: `scripts/design-harness/render.sh "screenMockups()"` → `docs/design/lm2/lm2b-*.png`.

### 9.1 The level section in Settings › Privacy

```
Screen                                                        [settingsHeading]
[ ] Let Zeus look at the window in front now and then           [switch]
Zeus takes a picture of the window in front at sensible moments, covers
private text and blurs faces on this Mac, and keeps a one-line description
of what you were doing. Never the whole screen.                [caption]

Record in   ( Everywhere except my private list | Only in apps I choose )
<list, §3>
Up to       ( 4 an hour | 12 an hour | 30 an hour )            [SettingsSegments, default 12]
Pictures that look the same as the last one don't count.       [caption]
Keep descriptions for   ( 30 days | 90 days )                  [default 90]
Pictures are deleted after 7 days.                             [caption]
```

- **Apple Intelligence off:** add the caption "Apple Intelligence is off, so Zeus keeps the covered pictures without descriptions."
- **Battery:** in Low Power Mode or below 30 % battery, Zeus still takes pictures but writes their descriptions later. There's no copy for this; it's invisible.

### 9.2 When Zeus looks ("smart timing")

This paragraph is used in the consent sheet and in SETUP.md:

> Zeus doesn't record your screen. It takes one picture of the window in front when something has changed: after you've switched to an app or document and stayed for 10 seconds, every 5 minutes if you stay in the same place, when you come back from a break, and when you ask. It skips the picture if the window looks the same as last time. It never takes one during a video call, while your screen is mirrored for a presentation, while a password field is active, or in private windows and apps on your private list.

### 9.3 Consent sheet, Level 3 (one time)

- **Title:** "Screen"
- **Body:** "Zeus takes a picture of the window in front at sensible moments, so your assistant knows what you were looking at. Before anything is kept, Zeus covers private text and blurs faces, here on this Mac."
- **"Zeus keeps"**
  - "A picture of the window in front, with private text covered and faces blurred, for 7 days"
  - "A one-line description of what you were doing, for 90 days"
- **"Zeus never keeps"**
  - "The rest of your screen or other windows"
  - "Anything during a video call or while presenting"
  - "Anything while a password field is active"
  - "Private windows and apps on your private list"
  - "Sound"
- **"When Zeus looks"**: the §9.2 paragraph.
- **"An example of what's kept"**: a 360×225 mock window in the field chrome.
  - It shows a browser page with two text lines covered by solid `fieldBorder` boxes with a 1-px `outline`, and a pixellated portrait.
  - Under it, monospaced: "10:12  Safari  Reviewing account information."
  - Caption: "Grey boxes are text Zeus covered. Faces are blurred. The picture is kept for 7 days, the description for 90."
- **Caveat** (caption): "Descriptions go to your assistant in summaries, like any message. Pictures never leave this Mac unless you attach one yourself."
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
  - Legend under it (caption): "▭ Covered text · ▭ Blurred face", with counts: "3 covered · 1 blurred".
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
