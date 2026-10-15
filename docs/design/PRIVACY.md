# Privacy surfaces: Learn from me, the journal and rules

The spec for everything the user sees about what Zeus observes, keeps, sends and decides (LM2 Phase A, levels 1–2, rules).
Copy in quotes is final unless the code needs to shorten it, in which case ask the designer.
Settings uses the system font and the existing Settings components (`settingsTitle`, `settingsBody`, `settingsCaption`, `settingsError`, `SettingsSegments`, `KeyboardButton`, `SettingsDivider`). There are no new ZeusDesign tokens.
Renders: `scripts/design-harness/render.sh "privacyMockups()"` → `build/q2-renders/lm2-*.png`, copied to `docs/design/lm2/`.

**Status by section:**

| Section | Phase | Status |
|---|---|---|
| §1–8: principles, Settings › Privacy levels 1–2, the coin and lists, What Zeus Kept, Settings › Rules, quiet lines, drop on Zeus, first run | A | ships in Phase A |
| §9 Level 3 · Screen, Ask About This | B | designed, not built |
| §10 Level 4 · Typing | C | designed, not built |
| §11 Raw on request, journal answers, acting rules, outcomes in Why? | D | designed, not built |

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

> **Phase A: ships in Phase A.**

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
- **Level 4, "Typing":** specified in §10 (Phase C).

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

> **Phase A: ships in Phase A.**

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

> **Phase B: designed, not built.**

Pipeline and costs: `docs/research/on-device-vision.md`. Renders: `scripts/design-harness/render.sh "screenMockups()"` → `docs/design/lm2/lm2b-*.png`.

**Pictures (PM decision, LM2-D2):**
- Every picture region in the frame larger than 48×48 px is pixellated by default.
- Whole-frame face detection runs as a cheap extra. There's no tiling at capture time.
- The copy says "pictures and faces are blurred".

### 9.1 The level section in Settings › Privacy

```
Screen                                                        [settingsHeading]
[ ] Let Zeus look at the window in front now and then           [switch]
Zeus takes a picture of the window in front at sensible moments, covers
private text and blurs pictures on this Mac, and keeps a one-line description
of what you were doing. Never the whole screen.                [caption]

Record in   ( Everywhere except my private list | Only in apps I choose )
<list, §3>
Up to       ( 4 an hour | 12 an hour | 30 an hour )            [SettingsSegments, default 12]
Pictures that look the same as the last one don't count.       [caption]
Keep descriptions for   ( 7 days | 30 days | 90 days )        [default 90]
Pictures are deleted after 7 days.                             [caption]
```

- **Apple Intelligence off:** add the caption "Apple Intelligence is off, so Zeus keeps the covered pictures without descriptions."
- **Battery:** in Low Power Mode or below 30 % battery, Zeus still takes pictures but writes their descriptions later. There's no copy for this; it's invisible.

### 9.2 When Zeus looks ("smart timing")

This paragraph is used in the consent sheet and in SETUP.md:

> Zeus doesn't record your screen. It takes one picture of the window in front when something has changed: after you've switched to an app or document and stayed for 10 seconds, every 5 minutes if you stay in the same place, when you come back from a break, and when you ask. It skips the picture if the window looks the same as last time. It never takes one during a video call, while your screen is mirrored for a presentation, while a password field is active, or in private windows and apps on your private list.

### 9.3 Consent sheet, Level 3 (one time)

- **Title:** "Screen"
- **Body:** "Zeus takes a picture of the window in front at sensible moments, so your assistant knows what you were looking at. Before anything is kept, Zeus covers private text and blurs pictures and faces, here on this Mac."
- **"Zeus keeps"**
  - "A picture of the window in front, with private text covered and pictures blurred, for 7 days"
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
  - Caption: "Grey boxes are text Zeus covered. Pictures and faces are blurred. The picture is kept for 7 days, the description for 90."
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
  - Legend under it (caption): "▭ Covered text · ▭ Blurred picture", with counts: "3 covered · 1 blurred".
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

> **Phase C: designed, not built.**

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

Keep the words   ( Don't keep | 24 hours | 7 days )            [SettingsSegments, default 24 hours]
Topics are kept for 30 days. The words, with private details removed, are kept as you choose here.   [caption]
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
  - "What each stretch of typing was about, for 30 days"
  - "The words, with private details removed, for 24 hours (you can change this, or keep no words at all)"
- **"Zeus never keeps"**
  - "Anything you type into a password field"
  - "Typing in apps you haven't chosen, or in private windows"
  - "What you paste: Zeus only notes that you pasted"
  - "Typing made by other apps, such as a password manager filling in a form"
- **"An example"**, in the field chrome:
  ```
  14:05  Mail  hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore
         → Replying to a doctor about rescheduling an appointment
  ```
  - Caption under it: "The first line is the words as kept for 24 hours. The second is the topic kept for 30 days, and the only part your assistant sees."
- **Caveat** (caption): "Topics go to your assistant in summaries, like any message. The words never leave this Mac."
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
- **Topics** are kept for 30 days and aren't configurable in v1.
- "Delete Everything…" covers both.

## 11. Phase D · depth: journal questions, acting rules, outcomes

> **Phase D: designed, not built.** The tools it relies on are in `AGENT_LEARNING.md` §3 and §5.

The assistant's side of all this is `docs/design/AGENT_LEARNING.md`. Renders: `scripts/design-harness/render.sh "depthMockups()"` → `docs/design/lm2/lm2d-*.png`.

### 11.1 "Raw on request" (per level)

- **Which levels:** only Level 3 (pictures) and Level 4 (words) have anything rawer than what the assistant already gets.
  - Level 1 and 2 records are already the stored form, so they have no switch.
  - Even "raw" is the **stored** form: covered pictures and redacted words. It's never the original screen or keystrokes.
- **The switch:** in each level's section, after retention, a checkbox. Off by default.
  - Level 3: "Let my assistant see the pictures when it asks"
  - Level 4: "Let my assistant see the words when it asks"
  - Caption: "Otherwise it gets only descriptions. Each time it looks, you'll see a line in the conversation."
  - Level 4's caption says "topics" instead of "descriptions".
- **The sheet on first turning it on**, titled "Let your assistant see pictures?" (Level 4: "…see the words?"):
  - **Body:** "When your assistant asks about a moment, it can get the picture Zeus kept (with private text covered and pictures blurred), not just the description. That picture goes to your assistant's model provider, like anything you send."
  - Level 4 body: "…it can get the words Zeus kept (with names, numbers and secrets removed), not just the topic. Those words go to your assistant's model provider, like anything you send."
  - **Caption:** "Every time it looks, the conversation says so, and What Zeus Kept › Sent to your assistant shows exactly what it got."
  - **Buttons:** "Cancel" and "Allow".
- **Turning it off** takes effect at once. There's no sheet.

### 11.2 The journal-answer line

When the assistant calls `zeus_get_journal`, the thread gets a quiet notice line (§6 style): no peek, no sound, not unread.

| Case | Line |
|---|---|
| Descriptions, titles and topics only | "Looked at your journal: Tue 14:00–15:30 · View" |
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

The shadow line first. One action, "OK next time?" (§6). The verb follows what the rule would have done:

| Verb | Shadow line |
|---|---|
| sent | "I'd have sent “Running late, 10 min” to the team chat · OK next time?" |
| posted | "I'd have posted the weekly summary to the project channel · OK next time?" |
| drafted | "I'd have drafted a reply to the scheduling email · OK next time?" |
| changed | "I'd have moved your 15:00 meeting to 15:30 · OK next time?" |
| bought | "I'd have bought the usual coffee beans for €14 · OK next time?" |
| booked | "I'd have booked the 8:10 train to the office · OK next time?" |

- After **OK:** "OK. I'll do that from now on. · Undo". Undo puts the rule back in shadow.
- **The acted line** appears once a rule is active and the assistant has acted, as a quiet line:
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
  ✓ Wed 15 Oct 18:05 · Held 2 messages; you read them at 19:10   (accepted)
  ↶ Thu 16 Oct 18:30 · You pressed Show before 19:00             (undone)
  – Fri 17 Oct · The prepared list wasn't opened                  (ignored)
  ✕ Sat 18 Oct · You pressed Skip on its question                 (skipped)
Fairly sure · was Sure on 15 Oct
```

- Glyphs: ✓ accepted, ↶ undone, – ignored, ✕ skipped, ○ turned off, ● turned on, ✎ edited. Each also has a text label in parentheses, and VoiceOver reads the label.
- Newest first, at most 10 entries, then "and 6 earlier".
- The last line is the current confidence word and its most recent change ("was Sure on 15 Oct"). It's never a number.
- With no outcomes yet: "Nothing has happened with this rule yet."
