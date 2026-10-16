# Learn from me

[Documentation](README.md) · [Privacy and security](PRIVACY.md) · [Settings defaults](SETTINGS.md#privacy)

Learn from me keeps a local record that your assistant can use for context, timing and rules. All four levels are independent and off by default. Open **Settings › Privacy** to choose them. Each first-use consent sheet explains its scope before capture starts.

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

Zeus writes a readable copy of retained learning into `Zeus/` inside the assistant folder. Only enabled levels contribute, after their privacy safeguards. This record accumulates independently of delivery: a disconnected assistant does not stop it growing.

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
| `Zeus/reflections/YYYY-MM-DD.md` | Reflection text. |
| `Zeus/rules.md` | Current rules, status, confidence and author. |
| `Notes/about-you.md`, `Notes/patterns.md` | Dated conclusions the assistant may write itself; Zeus does not write or read these files. |

These are ordinary readable files, separate from the encrypted internal journal. Files are written atomically with owner-only permissions. Keep your own material outside `Zeus/`: Zeus updates its records, and edits there can be overwritten. A file you remove in Finder stays removed from this export; that does not delete the internal journal record. Delete through **What Zeus Kept** to remove the retained source as well.

The version 2 template tells the assistant to read relevant records when useful, learn repeated tasks and preferences across days, revise its own notes, and propose rules supported by evidence. It must not repeat private observations unprompted or put them into material you did not ask it to send. Reading the folder does not itself authorize an action, and purchases still ask every time.

## What your assistant receives

A morning summary describes the previous day. With Apps and timing enabled, it is prepared at the first activity of a new day. Under **Notes to your assistant**, all four moment types are initially selected:

- **First activity of the day**
- **Back from a break of 2 hours or more**
- **A later start than usual**
- **Day winding down (no input for 20 min after 17:00)**

These produce up to four notes a day. Summaries can include context from other enabled levels. The deliveries carry descriptions and topics, not picture bytes or retained typing words. Those retained details are available separately in the folder.

At most once a day, Zeus prepares a reflection for the assistant: normally after ten minutes of idle time after 18:00, with a catch-up path for an earlier day. It includes redacted context, rule outcomes and evidence IDs. The assistant can use it to propose rules. A reflection is context, not a request to take an external action.

Summaries, notes and reflections end with a `Files:` line naming relevant available paths when an assistant-folder copy exists. The exact sent text, including those paths, appears in the Sent ledger. They use durable delivery and acknowledgment. A conversation line such as **Daily summary ready for your assistant** becomes **Sent your daily summary** after acknowledgment or tool-result consumption. **View** shows the exact text. Prepared but unreceived items appear under **Waiting** in the Sent view, with reasons such as a disconnected assistant, busy session or unsent Terminal draft. A hold lasting ten minutes gets an explanatory notice.

When you ask about your day, the assistant can query enabled journal levels using `zeus_get_journal`. It receives app activity descriptions, window titles, screen descriptions and typing topics. A request covers at most seven days and 50 records, with a limit of 20 calls an hour. With `raw: true`, it can also receive retained pictures or words from enabled levels. Pictures reflect the covering setting used when captured; words are already redacted. “Raw” means the stored form, not a copy from before safeguards.

Each successful journal answer is recorded in **Sent to your assistant**, with a **Looked at your journal** notice in the conversation. This records the result delivered to the assistant, not proof of what its model understood. Your assistant's model provider can receive that context like any other message.

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

**Sent to your assistant** shows exact outgoing summaries, notes, reflections, journal answers and context attachments. Expand a row to inspect it. **Waiting** items are separate from received records; they do not count as sent. This ledger covers learning/context delivery, not all ordinary chat or anything the assistant independently reads.

**Show Day in Finder** opens the selected day’s export when it exists. Record rows also offer **Show in Finder** in their context menu or hover actions; a missing item file falls back to its day folder when available.

**Export…** saves the displayed stored records as JSON. On the Sent tab it exports received records, not waiting items. Exporting is your own file copy.

## Pause, retention and deletion

**Pause for Today** stops observation until local midnight; **Resume** restarts it sooner. Turning a level off stops its observation and excludes it from journal-tool access. Existing records remain available in the viewer until retention or deletion removes them. The folder copy follows enabled levels too: disabling a level removes its exported records on the next refresh; re-enabling can restore still-retained records.

Delete an individual record, typing group, day, or all records from a selected app using the viewer. Individual deletions can offer **Undo**; day/app deletion and **Delete Both…** ask for confirmation. Retention and deletion update matching records in the current assistant folder; Undo restores an exported record when its source is restored. Existing sent receipts are separate evidence and are not removed by deleting only their source record.

**Delete Everything…** removes the learning journal, summaries and Sent ledger, and empties `Zeus/` in the current assistant folder after confirmation. **Also delete your assistant's notes** starts unchecked; select it to empty `Notes/` too. Other working files are left alone. It also discards affected pending summaries/reflections; a late acknowledgment cannot recreate a sent receipt. Already-pasted Terminal text is left alone. Rules are managed separately in **Settings › Rules**, and deletion cannot retract material already received by an assistant or its provider.

If the journal key is unavailable, new records wait in memory. Privacy explains the condition. Unlocking lets Zeus save them; quitting first loses those unsaved records.

## Rules

Rules guide timing, tone and work. **Settings › Rules** appears when a learning level is enabled or a rule exists. The default **New rules** dial is **Balanced**.

| Dial | Initial behavior |
|---|---|
| **Ask me first** | Proposals wait in **Suggested** until you turn them on. |
| **Balanced** | Passive timing/tone rules become active; acting rules start in shadow, waiting for approval. |
| **Just do it** | Passive rules start immediately. Acting rules still begin in shadow; the implemented approval path must be completed before they act. |

For an acting rule, the assistant first reports what it would have done. **OK next time?** approves the rule; **Not this** retires it. After an approved action, **Did: …** offers **Undo** when the assistant supplied a reversal instruction, otherwise **Not again**. Undo asks the original assistant to reverse the action; it does not guarantee the external action can be undone.

Purchases always require a fresh, amount-specific approval. A spending rule never becomes standing permission to pay. Zeus records approvals and reported actions; the assistant performs external work through its own tools and permissions.

Passive rules with evaluable time, app or state conditions can hold routine peeks and sounds. Cards still enter the thread and count as unread. When a hold clears, Zeus can show the newest eligible unread card. Urgent cards bypass the rule hold. A rule with no evaluable trigger is guidance for the assistant and does not hold the UI.

Use a rule's **… › Why?** to see its retained evidence and dated outcomes. Acceptance, skips, ignoring, edits, toggles and Undo affect confidence. It is shown as **Sure**, **Fairly sure** or **Unsure**. Agent rules that lose enough confidence retire; rejected, disabled or deleted proposals are suppressed for 30 days. User-authored rules do not retire automatically.

**Add Rule…** creates a passive rule. You can edit its sentence, days, time window, apps and state; **Save** applies it. For an acting rule, ask the assistant to propose one. **Turn Back On** restores a retired rule; acting rules return through shadow approval.

Implementation references: [learning settings](../Zeus/Learn/LearnSettings.swift), [level policies](../Zeus/Settings/ObservationSettings.swift), [learning presentation](../Zeus/Settings/LearningPresentation.swift), [journal queries](../Zeus/Bridge/ZeusRuntime+Journal.swift), [rules](../Zeus/Learn/PersistentRulesStore.swift), [rule actions](../Zeus/Bridge/ZeusRuntime+RuleActions.swift), [folder writer](../Zeus/Learn/LearningFolderWriter.swift) and [folder routing](../Zeus/Bridge/ZeusRuntime+LearningFolder.swift).
