# Learn from me

[Documentation](README.md) · [Privacy and security](PRIVACY.md) · [Settings defaults](SETTINGS.md#privacy)

Learn from me keeps a local record that your assistant can use for context, timing and rules. All four levels are independent and off by default. Open **Settings › Privacy** to choose them. Each first-use consent sheet explains its scope before capture starts.

Message ratings and the [morning brief](#morning-brief) work with every observation level off. You can [rate what you hear about](CONVERSATION.md#rate-what-you-hear-about) without enabling capture.

## Levels at a glance

| Level | Keeps | Initial retention |
|---|---|---|
| **Apps and timing** | App use, launches/quits, idle time, lock/sleep/wake and display count. | 90 days; summaries one year. |
| **Windows and pages** | Front-window titles, document references and supported browser addresses. | 90 days. |
| **Screen** | Occasional pictures of the front window and descriptions; picture covering starts on. | Pictures 7 days; descriptions 90 days. |
| **Typing** | Topics from typing in chosen apps, plus redacted words if retained. | Topics 30 days; words 24 hours. |

Higher levels do not require turning on all lower levels. They still need their own consent, app scope and macOS permissions.

## Permissions

| Level | Permission | What to do |
|---|---|---|
| Apps and timing | None | Confirm the consent sheet. |
| Windows and pages | Accessibility | Allow Zeus in System Settings › Privacy & Security › Accessibility. |
| Screen | Screen Recording | Allow Zeus in Screen & System Audio Recording, then use **Reopen Zeus** when requested. |
| Typing | Input Monitoring | Allow Zeus in Input Monitoring, then reopen when requested. Apple Intelligence must also be available. |

Zeus asks from the consent flow, rather than repeatedly prompting later. A missing or revoked permission produces a caption under the level with **Open System Settings** or **Reopen Zeus**. Other enabled levels continue independently. Browser access can also depend on macOS allowing Zeus to communicate with that browser.

## App scope and private windows

The first three levels offer **Record in**:

- **Everywhere except my private list** (default).
- **Only in apps I choose**, with a separate app list for that level.

Typing always uses **Only in apps I choose**. Its list starts empty. An empty chosen-app list records nothing for that level. **Add App…** adds an app; the minus button removes it.

The shared private list takes precedence at every level. It initially includes 1Password, Bitwarden, KeePassXC, Strongbox, Enpass, Dashlane, Keychain Access, Passwords and System Settings. At the activity level, private app use contributes only unnamed private time. Window, picture and typing details are not captured for private-list apps.

**Safari is an explicit exception to private-window detection.** By default Zeus keeps only app-level Safari activity, not its titles, addresses, pictures or typing. Adding Safari under **Only in apps I choose** for a higher level permits that level's details, including private windows, because Zeus cannot distinguish them. The app displays this limitation beside Safari. Selected text for Ask About This is more restrictive and can be omitted even when Safari titles are allowed.

Chrome and Edge private windows are excluded. Other recognized browsers whose window privacy cannot be established are treated as private, even when chosen. Secure input and a locked screen also stop detailed capture. These checks use the privacy state reported by macOS and the browser.

## Apps and timing

Turn on **Let Zeus learn when and in what I work**. This records which app is in front, app launches and quits, locking, sleeping, waking, periods without input for at least five minutes, and display count.

This level does not read typed or pasted content, window titles, addresses, filenames, screenshots, sound or location. **What Zeus has recorded** lists today's events in the Privacy pane.

**Keep activity for** offers 7, 14, 30, 60 or 90 days. Older activity is pruned automatically. Summaries are retained for one year.

## Windows and pages

Turn on **Let Zeus keep window titles and web addresses**. With Accessibility allowed, Zeus keeps changes to the title of the front window and the document it represents. Chrome and Edge can supply the current page address after their privacy check. Safari follows the exception above.

This level does not continuously read a window's body. A title can itself contain content, such as an email subject. It goes through redaction before storage; removed details appear as placeholders such as `‹name›`.

**Keep for** offers 7, 30 or 90 days, defaulting to 90.

## Screen

Turn on **Let Zeus look at the window in front now and then**. Zeus captures one front window, not a recording of the whole display or sound.

Capture opportunities are an app or document change after ten seconds of dwell, five minutes in the same context, return from idle, and an on-demand request. Unchanged pictures are skipped. **Up to** limits capture to 4, 12 or 30 pictures an hour (default 12).

Capture stops while a camera is in use, during detected presentation or display mirroring, with secure input active, on the lock screen, in excluded apps, and for private or unknown browser windows, subject to the Safari exception. Password dialogs and known sensitive banking/Keychain contexts are also rejected. The caption explains a current pause.

**Cover pictures and faces** starts on. Before saving, Zeus reads the frame with Vision, covers detected private text with solid boxes, and pixellates detected picture regions and faces. An on-device description summarizes the redacted text and window metadata. If Apple Intelligence is unavailable, descriptions use a simpler local fallback. Low Power Mode or a low battery can defer descriptions.

Turning **Cover pictures and faces** off opens **Keep pictures uncovered?**, with **Keep Covering** and **Turn Off**. After confirmation, new frames keep pictures, faces and ordinary text uncovered. Detected passwords, keys, card/account numbers and identity numbers are still covered. Capture exclusions still apply, including the Safari exception above. Text descriptions still use the full redaction pipeline. Previously stored frames do not change when you toggle the switch.

Pictures are retained for seven days. **Keep descriptions for** offers 7, 30 or 90 days (default 90). Retained pictures are available in the assistant folder and, on request, through the journal tool while Screen is enabled. There is no separate picture-access switch.

## Typing

Turn on **Let Zeus keep what I type in apps I choose**, then choose apps. Typing requires the on-device model to be available as well as Input Monitoring permission.

Zeus groups keys into short runs, ending a run after two seconds without typing or a change of focus. It redacts the words and derives a one-line topic. The observer is listen-only. It ignores synthetic typing, and does not read pasted text: a paste can be represented by `‹pasted›` instead. Input methods that cannot be translated safely produce an app-only record without words or a topic.

When macOS secure input is active, typing capture stops and an in-progress run is discarded. The menu reads **Private input: Zeus isn't noting typing**. Private windows and the shared private list also stop capture, with the Safari exception described above.

**Keep topics** offers 7, 30 or 90 days (default 30). **Keep the words** offers **Don't keep**, **24 hours** (default) or **7 days**. Shortening retention deletes older content immediately. Words cannot outlive their topic. Very short runs keep only a topic, and a run consisting entirely of a secret pattern is dropped.

The assistant folder contains the retained redacted words. The journal tool can also return them on request while Typing is enabled. There is no separate word-access switch; **Keep the words** determines whether words remain available.

## Your assistant's folder

Zeus writes a readable copy of retained learning into `Zeus/` inside the assistant folder. Observations come only from enabled levels, after their privacy safeguards. Explicit message ratings also have a folder record, independent of those switches. This record accumulates independently of delivery: a disconnected assistant does not stop it growing.

- With **Zeus runs it**, the destination is the running conversation’s working folder. A folder switch deferred with **Later** keeps writing to the old folder until the switch is applied.
- With **Connect your own**, open **Settings › Privacy › Your assistant's folder**, then **Choose…**. No destination is selected by default. **Stop keeping a folder** stops future writes and leaves the existing folder alone.
- **Show in Finder** opens the record. The path and any write error appear in Privacy. Where the folder lives is your choice; if it syncs, the records sync with it.

Choosing a destination backfills retained history for enabled levels. Changing destinations backfills the new one and leaves the old one alone. The old copy no longer follows retention or deletion in the current destination.

| Path inside the assistant folder | Contents |
|---|---|
| `Zeus/README.md` | The layout and ownership rules. |
| `Zeus/days/YYYY-MM-DD/activity.md` | Activity timeline; private apps remain unnamed. |
| `Zeus/days/YYYY-MM-DD/focus.md` | Redacted window/document titles and addresses. |
| `Zeus/days/YYYY-MM-DD/screen/` | Retained JPEG pictures and Markdown descriptions, named with time, app and a distinguishing suffix. |
| `Zeus/days/YYYY-MM-DD/typing.md` | Topics and redacted words while retained. |
| `Zeus/days/YYYY-MM-DD/summary.md`, `moments.md` | Summaries and notes, including items still waiting for delivery. |
| `Zeus/days/YYYY-MM-DD/sent.md`, `outcomes.md` | Stored delivery receipts and rule outcomes when present. |
| `Zeus/reflections/YYYY-MM-DD.md` | The same four-week pattern summary and instructions sent to the assistant. |
| `Zeus/rules.md` | Current rules, status, confidence and author. |
| `Zeus/preferences.md` | Current kind ratings under Up, Need-to-know and Stop, with redacted examples; excludes single-message ratings. |
| `Notes/about-you.md`, `Notes/patterns.md`, `Notes/preferences.md` | Dated conclusions and communication preferences the assistant may write itself; Zeus does not write or read these files. |

These are ordinary readable files, separate from the encrypted internal journal. Files are written atomically with owner-only permissions.

Zeus updates the files it wrote, so edits to those files can be overwritten. Other files in `Zeus/` are left alone. If one occupies a path Zeus needs, **Settings › Privacy › Your assistant's folder** reports **Zeus didn't replace …**. Move or rename that file to let Zeus write there.

A file you remove in Finder stays removed from this export; that does not delete the underlying journal records or preferences. Delete observations through **What Zeus Kept**; manage kind ratings under **Settings › Rules › What you hear about**.

The version 7 template tells the assistant to read relevant records when useful, learn repeated tasks and preferences across days, revise its own notes, and propose rules supported by evidence. It must not repeat private observations unprompted or put them into material you did not ask it to send. Reading the folder does not itself authorize an action, and purchases still ask every time.

## Morning brief

Start the day with what needs your attention. Zeus asks your assistant for one short brief: what's coming up, what's at risk, and what it has prepared. The template asks for a card titled **Today**, with at most six lines and the kind **Morning brief**. If nothing matters today, the assistant should acknowledge the request and send nothing.

Find **Ask my assistant for a morning brief** under **Settings › Assistant › Morning brief**. It starts on for **Zeus runs it**, off for **Connect your own**; your explicit choice is saved. **When** offers **After my first activity** (the default) or **At a fixed time**, initially 08:00 local time. Zeus queues at most one request per local day, including across relaunch. Waking the Mac alone is not activity. A fixed time missed while Zeus was closed is reconsidered when it opens or the Mac unlocks.

The brief works with any learning level, or all levels off. With learning off, the request contains no journal data; the assistant can use its own `Notes/`, rules and calendar, mail or task tools if available. Detecting the start of your day uses only recent input timing, not the contents of what you type. With learning enabled, the request can include redacted descriptions and topics from yesterday's permitted records, never picture bytes or retained typing words. The previous-day summary remains a separate learning record.

Rate the **Morning brief** kind with **More like this**, **Neutral** or **Stop these**, just like other unprompted messages. **Stop these** holds matching messages; turning off **Ask my assistant for a morning brief** stops the requests themselves.

A prepared request appears as **Morning brief request ready for your assistant**. After acknowledgment or successful submission of a [short delivery pointer](ASSISTANT.md#long-deliveries), **Sent the morning brief request · View** shows the full prepared text. In **What Zeus Kept › Sent to your assistant**, **Waiting** can contain a **Morning brief request** while the assistant is disconnected, busy or has an unsent Terminal draft. These are request receipts, not confirmation that the assistant has produced a brief.

## What your assistant receives

A morning summary describes the previous day. With Apps and timing enabled, it is prepared at the first activity of a new day. Under **Notes to your assistant**, all four moment types are initially selected:

- **First activity of the day**
- **Back from a break of 2 hours or more**
- **A later start than usual**
- **Day winding down (no input for 20 min after 17:00)**

These produce up to four notes a day. Template v7 asks the assistant to decide whether a summary or note calls for useful preparation or something to flag now, then send one short labeled message if needed; otherwise it acknowledges quietly. It must respect ratings and action approvals.

Summaries can include context from other enabled levels. The deliveries carry descriptions and topics, not picture bytes or retained typing words. Those retained details are available separately in the folder.

The [evening reflection](#evening-reflection) connects patterns across the last four weeks and asks the assistant to update its notes, consider supported rules, then prepare for tomorrow or stay quiet.

Summaries, notes and reflections end with a `Files:` line naming relevant available paths when an assistant-folder copy exists. The exact sent text, including those paths, appears in the Sent ledger. They use durable delivery and acknowledgment. A conversation line such as **Daily summary ready for your assistant** becomes **Sent your daily summary** after acknowledgment or tool-result consumption, or when a [short delivery pointer](ASSISTANT.md#long-deliveries) is successfully submitted. **View** shows the exact text. Pending deliveries appear under **Waiting** in the Sent view, with reasons such as a disconnected assistant, busy session or unsent Terminal draft. A hold lasting ten minutes gets an explanatory notice.

When you ask about your day, the assistant can query enabled journal levels using `zeus_get_journal`. It receives app activity descriptions, window titles, screen descriptions and typing topics. A request covers at most seven days and 50 records, with a limit of 20 calls an hour. With `raw: true`, it can also receive retained pictures or words from enabled levels. Pictures reflect the covering setting used when captured; words are already redacted. “Raw” means the stored form, not a copy from before safeguards.

Each successful journal answer is recorded in **Sent to your assistant**, with a **Looked at your journal** notice in the conversation. This records the result delivered to the assistant, not proof of what its model understood. Your assistant's model provider can receive that context like any other message.

## Evening reflection

The evening reflection helps the assistant learn patterns that last. Zeus builds it on your Mac from the last **28 local days** of retained records, using whatever history exists. It can prepare one reflection per day, normally after ten minutes idle after 18:00, with a catch-up path for an earlier day. At least one learning level must be enabled; unlike the morning brief, it does not run with all learning off.

The summary groups **Rhythm**, **Focus**, **Sequences**, **Topics**, **Engagement** and **Today vs usual** when there is evidence: typical starts and breaks, apps you return to, repeated app sequences, recurring topics, responses to assistant messages, and what changed today. Pattern lines cite evidence from different local days; dates and times use the Mac's local calendar. Time estimates are approximate, not a complete record of working hours. A short appendix keeps at most 20 records from the selected day.

Only already-redacted observations from currently enabled levels contribute. Typing contributes topics, never retained words; pictures are not included. Building the summary captures nothing new. It also includes message preferences, rule outcomes and **Don't propose again** guidance for rules you turned off, deleted or retired. The folder copy under `Zeus/reflections/` contains the same text.

Template v7 asks the assistant to do three things in order:

1. **Update your notes.** Revise `Notes/about-you.md` and `Notes/patterns.md`, dating each change and explaining what changed its mind. Keep conclusions, not copies of the reflection.
2. **Propose rules, if any.** Read the current rules, then propose at most three useful rules only for a pattern that held on two or more days, citing evidence from different local days in that reflection. No proposal is needed when the evidence does not support one.
3. **Get ahead of tomorrow.** If something needs preparing or flagging, do the preparation and send one short labeled message; otherwise acknowledge quietly.

The reflection is not a new request from you or permission for an external action. Acting rules still start in shadow, and every purchase asks. The assistant must not narrate your habits or repeat private details unprompted. **Sent a daily reflection · View** lets you inspect the exact text; [long deliveries](ASSISTANT.md#long-deliveries) explain why a Sent receipt can precede the assistant fetching or acting on it.

## Message preferences

**More like this**, **Neutral** and **Stop these** tell the assistant what kinds of unprompted messages you want. Neutral means need-to-know, by the assistant's judgment. Stop also applies a local hold to matching new messages; replies are exempt. These preferences are separate from acting rules and do not authorize external actions. See [rating controls and muted messages](CONVERSATION.md#rate-what-you-hear-about).

Each rating, edit, removal, Undo or **Not this kind** correction is saved and queued for the assistant, even with capture off. It includes the kind and scope, plus a redacted example for a rating. A `Files: Zeus/preferences.md` line is added when that exported file exists. **Just this one** feedback is delivered but does not enter the file's kind list or create a hold.

The assistant template v7 tells the assistant to read `Zeus/preferences.md` at session start and after rating deliveries, generalize preferences across wording, and keep dated conclusions in its own `Notes/preferences.md`. Zeus writes the first file and does not read or update the second. Current preferences also enter reflections when those are produced.

The saved rating confirmation does not mean the assistant has received it. **What Zeus Kept › Sent to your assistant** shows a receipt as **Sent your message preference** after acknowledgment, successful polling, or submission of a short delivery pointer; expand it for the exact text. Pending deliveries appear under **Waiting**. There is no additional conversation receipt notice for ratings.

## Ask About This

Choose **Ask About This** from the Zeus menu, or add Shift to your Talk shortcut (**⇧⌥⌘Z** by default). If the Talk shortcut already uses Shift, use the menu.

The conversation opens with context chips from the front window when the enabled levels and permissions allow it:

| Chip | Source |
|---|---|
| Window | Front-window title/document context from Windows and pages. |
| Selection | Selected text available through Accessibility. |
| Page | A permitted browser address. |
| Picture | A front-window capture from Screen, using the current picture-covering setting. |

Hover a chip to inspect its content and remove any chip you do not want to send. Nothing is sent until **Send**. Private, unavailable or disabled context is omitted with an explanatory caption. With neither relevant level enabled, the conversation still opens and explains what to turn on. Sent context attachments have their own ledger receipt.

## What Zeus Kept

Press **Open What Zeus Kept…** in Privacy.

**Kept on this Mac** shows records as stored, including placeholders. Choose a day, filter by level or app, and search. Picture rows open the stored frame with its description and retention date. **Show in Finder** opens its exported file when available. **Delete Picture** keeps the description; **Delete Both…** asks before removing both. Typing is grouped by app and hour, with topics above any retained words.

**Sent to your assistant** shows exact outgoing summaries, notes, reflections, morning brief requests, rule triggers, message preferences, journal answers and context attachments. Expand a row to inspect it. **Waiting** items track pending delivery or acknowledgment. A successfully submitted short pointer records the full text as Sent before acknowledgment; that receipt does not prove the assistant fetched or understood it. This ledger covers learning/context delivery, not all ordinary chat or anything the assistant independently reads.

**Show Day in Finder** opens the selected day’s export when it exists. Record rows also offer **Show in Finder** in their context menu or hover actions; a missing item file falls back to its day folder when available.

**Export…** saves the displayed stored records as JSON. On the Sent tab it exports saved Sent receipts, not the pending queue. Exporting is your own file copy.

## Pause, retention and deletion

**Pause for Today** stops observation until local midnight; **Resume** restarts it sooner. Turning a level off stops its observation and excludes it from journal-tool access. Existing records remain available in the viewer until retention or deletion removes them. The folder copy follows enabled levels too: disabling a level removes its exported records on the next refresh; re-enabling can restore still-retained records.

Pausing or disabling observation does not disable ratings, their delivery, or `Zeus/preferences.md`.

Delete an individual record, typing group, day, or all records from a selected app using the viewer. Individual deletions can offer **Undo**; day/app deletion and **Delete Both…** ask for confirmation. Retention and deletion update matching records in the current assistant folder; Undo restores an exported record when its source is restored. Existing sent receipts are separate evidence and are not removed by deleting only their source record.

**Delete Everything…** removes the learning journal, summaries, Sent ledger, message ratings, matching decisions and quiet-signal history, and the files Zeus wrote in `Zeus/` inside the current assistant folder after confirmation. Anything else in that folder stays. **Also delete your assistant's notes** starts unchecked; selecting it deletes everything in `Notes/`, including files you or your assistant put there. This can't be undone.

Deletion also discards pending rating deliveries and affected summaries/reflections; a late acknowledgment cannot recreate a sent receipt. Already-pasted Terminal text is left alone. Rules are managed separately in **Settings › Rules**, and deletion cannot retract material already received by an assistant or its provider.

If the journal key is unavailable, new records wait in memory. Privacy explains the condition. Unlocking lets Zeus save them; quitting first loses those unsaved records.

## Rules

Rules guide timing, tone and work. **Settings › Rules** is always available, with **What you hear about** above the rule controls. The default **New rules** dial is **Balanced**.

| Dial | Initial behavior |
|---|---|
| **Ask me first** | Proposals wait in **Suggested** until you turn them on. |
| **Balanced** | Passive timing/tone rules become active; acting rules start in shadow, waiting for approval. |
| **Just do it** | Passive rules start immediately. Acting rules still begin in shadow; the implemented approval path must be completed before they act. |

When an acting rule's time, app or state conditions start matching, Zeus sends the assistant a **Rule trigger** with the rule, what matched and whether it is in shadow or active. This includes preparation such as drafting a recap. Passive timing/tone rules do not send trigger deliveries; guidance without a checkable condition does not fire.

Zeus sends one trigger per matching window. A timed window does not repeat just because you switch away from and back to its app; a context-only trigger can fire again after its conditions stop matching and then match again. Pending triggers wait behind busy sessions and unsent drafts, and are cancelled when the window closes or the rule's status changes. Approving a shadow rule does not trigger it again in the same window.

For a shadow rule, the assistant reports what it would have done through `zeus_rule_shadow` and must not perform the action. For an active rule, it can act within its permissions while the trigger is still valid, then report promptly through `zeus_rule_acted`; if nothing needs doing, it acknowledges quietly. **Sent a rule trigger: “…” · View** records delivery of the trigger, not completion of the action.

The shadow report asks **OK next time?** to approve the rule; **Not this** retires it. After an approved action, **Did: …** offers **Undo** when the assistant supplied a reversal instruction, otherwise **Not again**. Undo asks the original assistant to reverse the action; it does not guarantee the external action can be undone.

Purchases always require a fresh, amount-specific approval. A spending rule never becomes standing permission to pay. Zeus records approvals and reported actions; the assistant performs external work through its own tools and permissions.

Passive rules with evaluable time, app or state conditions can hold routine peeks and sounds. Cards still enter the thread and count as unread. When a hold clears, Zeus can show the newest eligible unread card. Urgent cards bypass a timing-rule hold, but cannot bypass a stopped message kind. A rule with no evaluable trigger is guidance for the assistant and does not hold the UI.

Use a rule's **… › Why?** to see its retained evidence and dated outcomes. Acceptance, skips, ignoring, edits, toggles and Undo affect confidence. It is shown as **Sure**, **Fairly sure** or **Unsure**. Agent rules that lose enough confidence retire; rejected, disabled or deleted proposals are suppressed for 30 days. User-authored rules do not retire automatically.

**Add Rule…** creates a passive rule. You can edit its sentence, days, time window, apps and state; **Save** applies it. For an acting rule, ask the assistant to propose one. **Turn Back On** restores a retired rule; acting rules return through shadow approval.

Implementation references: [learning settings](../Zeus/Learn/LearnSettings.swift), [level policies](../Zeus/Settings/ObservationSettings.swift), [learning presentation](../Zeus/Settings/LearningPresentation.swift), [journal queries](../Zeus/Bridge/ZeusRuntime+Journal.swift), [rules](../Zeus/Learn/PersistentRulesStore.swift), [rule actions](../Zeus/Bridge/ZeusRuntime+RuleActions.swift), [briefs, triggers and daily limit](../Zeus/Bridge/ZeusRuntime+Proactive.swift), [reflection patterns](../Zeus/Bridge/ReflectionPatternDigest.swift), [reflection instructions](../Zeus/Bridge/ZeusRuntime+ReflectionPatterns.swift), [folder writer](../Zeus/Learn/LearningFolderWriter.swift) and [folder routing](../Zeus/Bridge/ZeusRuntime+LearningFolder.swift).
