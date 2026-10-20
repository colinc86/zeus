# The conversation and character

[Documentation](README.md) · [Characters and themes](CUSTOMIZATION.md) · [Your assistant](ASSISTANT.md)

## Open and close

Click the character or press **⌥⌘Z** to open the conversation. The message field receives focus. Click Zeus again, press Escape, or switch to another app to close it. A draft survives closing and reopening the panel during the current Zeus process.

When a question or unread message needs attention, clicking Zeus opens at that item. The global shortcut is configurable under **Settings › General › Talk shortcut** and needs no Accessibility permission.

Drag the character to move it. The conversation follows it and stays inside the visible screen. Right-click Zeus for the same menu as the menu bar icon.

## Messages and answers

Type in the message field and press Return to send. Shift+Return inserts a line break. The field grows to six lines before scrolling.

The **Replying to:** chip identifies the question your text will answer. Zeus prefers the newest open question that accepts text, then falls back to the newest ordinary options-only question. A question jump can explicitly select an older question. Clear the chip with its ×, **⌘K**, or Backspace in an empty field to send a new message instead.

Clicking an option answers that specific question, even when it is far back in the thread. **⌘1–⌘9** chooses an option on the newest open question or content card with actions. **Skip** closes an ordinary question without an answer and tells the assistant to move on. Native agent permission prompts cannot be skipped this way.

When Zeus can recognize a managed agent's permission prompt, its card shows the agent's choices. Zeus verifies that the prompt has not changed before sending your choice. Login, trust and unrecognized prompts need **Open in Terminal**.

## Rate what you hear about

Hover an assistant message, question or finished-work card sent on its own, then click **⋯** to rate its kind. The button is also keyboard-focusable; in a peek, it opens the conversation at that message. Replies to your own messages or answers have no rating menu. Zeus decides whether a card is a reply: every message the assistant sends while answering your message or answer counts, until its turn ends, Zeus sends it something else, or it goes quiet for half an hour. The assistant cannot choose that classification. Older cards without this classification and local/progress cards have no menu.

| Choice | Meaning |
|---|---|
| **More like this** | Keep telling me about this kind. Zeus delivers new messages normally. |
| **Neutral** | **Only when I need to know**. The assistant decides what is worth sending; Zeus delivers what it sends normally. |
| **Stop these** | Stop sending this kind. Zeus holds matching new unprompted messages, even when marked high priority. |

The line **For all “On-call reminders”** shows the kind being rated. **Edit** changes the label, up to 60 characters; Return finishes editing and Escape cancels. A blank edit restores the previous label. Then choose a rating to save it. The initial label comes from the assistant's `about` label, falling back to its title or the start of its text.

Choose **Just this one** before a rating to give feedback on only that message. The line becomes **For this message only**, with **All of this kind** to switch back. Single-message feedback does not create a kind preference or mute anything, including the rated message.

A saved kind rating shows a confirmation such as **Stopped: On-call reminders · Undo**. Reopen the row to change the choice or use **Remove rating**. **Undo** restores the previous preference while available, including after relaunch; a later preference change invalidates it. Undo sends a new correction to the assistant and cannot recall an earlier delivery.

Press **⌘R** to toggle ratings for the focused eligible message, or the newest eligible message when none is focused. Tab or arrow keys move through the choices and links; Return activates. Escape first cancels a label edit, then closes the rating row without closing the conversation. VoiceOver offers **Rate: more like this**, **Rate: only when I need to know** and **Rate: stop these** actions.

All kind preferences are under [Settings › Rules › What you hear about](SETTINGS.md#what-you-hear-about). Ratings work with all Learn from me levels off, including for the **Morning brief** kind. Ratings are how you tell the assistant how much to send. Zeus never holds a message back because of how many the assistant has sent.

## Muted messages

A stopped kind stays in the thread as **Muted: On-call reminder · Show**. It produces no peek, sound, unread badge or waiting-question indicator. **Show** expands the retained message and becomes **Hide**; it does not remove the hold. Attachments and the message's own answer buttons remain available.

The explanation reads **Stopped kind: On-call reminders** for a label match, or **Looks like On-call reminders** for an on-device similarity match. Exact matching ignores case, punctuation, accents and spacing. When no exact rated label matches, Zeus compares the label and message text with stopped kinds. Similarity can miss a look-alike or hold an unrelated message; if the language's local model is unavailable, exact matching still works.

- **Not this kind** releases this message without changing the kind preference or replaying its alert. It records a correction, with guarded **Undo**.
- **Change rating** opens the inline rating row for the matched kind. Changing or removing a kind rating affects new messages; already-held messages stay available through **Show**.

At the start of quiet hours, or 21:00 local time when quiet hours are off, a quiet line such as **3 muted messages today · Show** opens that day's held messages. **Settings › Rules › What you hear about** also offers **Muted today: 3 · Show**. Muting itself does not delete cards; normal conversation-history rules still apply.

After five messages of an unrated, labeled kind within seven days go unread for 24 hours or are dismissed within three seconds of display, Zeus may show **Getting a lot of On-call reminders · Rate them · Not now**. **Rate them** opens a message's rating row; **Not now** dismisses the suggestion for that kind. These signals never create a rating or mute messages automatically.

## No daily limit

Zeus 0.3.8 held unprompted messages after the sixth of the day as **Held: over today's limit**. That limit is gone: only your ratings quiet messages. Messages it held become ordinary messages in your history when Zeus starts; they don't peek or play a sound again.

## Cards and history

| Item | What it shows |
|---|---|
| Message | An assistant update or reply, with formatted text and links. |
| Question | Choices, a text reply target, or both. |
| Finished work | A title, summary, attachments and optional actions. |
| Progress | An update in place, with a progress bar when supplied. |
| Activity | A thinking or working indicator while the assistant responds. |
| Notice | A quiet line for an app change, learning receipt, rule or restart. |

New messages follow the thread when you are at the bottom. If you scroll back, new arrivals leave your place alone and show a jump-to-latest control. Sending a message returns you to the newest part of the conversation.

History is saved locally. Zeus retains the newest 500 history cards plus pending or unsaved outgoing messages. **Clear Conversation…** asks first and preserves unread messages, open questions and actions, and unsent or unconfirmed messages. It does not clear the learning journal, reset message ratings, or reset the assistant's native conversation.

## Attachments from your assistant

Read the takeaway in the message, then decide whether to open the attachment. Each new file or folder comes with the assistant's short summary of what is inside and why it matters. Links may have a summary too. Older attachments without one still show their names.

Each chip shows a file, folder or link icon, its name, and up to two lines of summary. Long names shorten in the middle. **More** expands an overflowing summary in place; **Less** collapses it. Click the chip to open it. Finished-work cards can also have separate action buttons chosen by the assistant.

For an ordinary file or folder, hover or focus the chip to reveal the **Show in Finder** icon. Right-click for the available **Open**, **Show in Finder** and **Copy Path** actions; links offer **Open** and **Copy Link**. With the chip focused, Return or Space opens it; **⌘Return** shows a file or folder in Finder. VoiceOver reads the kind, name and full summary and offers the available attachment actions.

Files open in their usual apps, folders in Finder, and links through macOS. Apps, scripts and other executable targets are shown in Finder instead of run. A missing file shows **Not found**; clicking it reveals the nearest existing parent folder. Attachments remain available in older messages, subject to the file still being there.

## Attach things

Drag files, folders, images, text or links onto Zeus. The conversation opens with removable attachment chips. Nothing is sent until you press **Send**, and attachments can be sent without text. You do not need to write a summary for material you drop here.

A dropped folder offers **Work in this folder** when Zeus runs the assistant. This uses the normal folder-switch confirmation and starts a new assistant conversation.

Dropped material is not added to Learn from me. To attach context from the current window with the learning safeguards applied, use [Ask About This](LEARNING.md#ask-about-this).

## Speech bubbles (peeks)

When the conversation is closed, a new message, question or finished-work card can appear as a small bubble beside Zeus. It does not take keyboard focus. Click the bubble to open the full conversation; up to three choices can be answered directly in it.

A peek shows the first attachment as a compact chip with one line of summary. Click the chip to open it; a link such as **and 1 more attachment** opens the conversation for the rest. Open the conversation to expand a summary or use Finder and copy actions.

Ordinary peeks disappear after a reading interval of 6–15 seconds, with the timer paused while you hover. High-priority peeks wait for interaction. New arrivals replace the current peek and show how many more messages are waiting. Status and progress updates do not create peeks.

Quiet hours and hiding suppress peeks and sounds. Active timing rules can hold routine peeks while still keeping the cards and unread badge. High-priority cards bypass a timing-rule hold, but do not override an explicit hide, quiet hours, or a **Stop these** rating. A peek that times out without interaction leaves its message unread.

The typewriter effect plays once per card. Click revealing text to finish it immediately. General settings control the effect, retro blip and optional pop-up sound. Reduce Motion suppresses the reveal and blip.

## Status strip

The line between the thread and message field explains what needs attention. Click its sentence or press **⌘J** to jump there.

| Situation | Action |
|---|---|
| A question is waiting | Go to the question; repeated jumps cycle through waiting questions. |
| Unread messages | Go to the first unread message. |
| A managed Terminal prompt | Go to the mirrored prompt, or open Terminal. |
| The assistant is working | Go to the current activity at the bottom. |
| A message was not delivered | Go to the affected message. |
| Quiet hours | Read when the quiet period ends. |

The strip's quick actions are **Open in Terminal**, **Start New Conversation…**, **Clear Conversation…** and **Assistant Settings…**. Availability depends on the session and whether there is anything to clear. **Skip** applies to the oldest ordinary question.

The character's pose reflects new messages, explicit assistant status, unread items, work, questions and quiet hours. The status strip is the more specific explanation; a question mark alone does not tell you which question is waiting.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **⌥⌘Z** | Open or focus Talk to Zeus; close it when already focused. Configurable. |
| **⇧⌥⌘Z** | Ask About This. Derived by adding Shift to the Talk shortcut when possible. |
| **Return** | Send from the message field; open a focused attachment chip. |
| **⌘Return** | Show a focused file/folder attachment in Finder. |
| **⇧Return** or **⌥Return** | Insert a line break. |
| **Escape** | Cancel a rating label edit or close its row first; otherwise close the current popover or conversation. |
| **⌘R** | Open/close ratings for the focused eligible message, or the newest eligible message. |
| **⌘1–⌘9** | Choose an option on the newest actionable card. |
| **⌘K** | Clear the reply chip. |
| **⌘J** | Jump to the item named in the status strip. |
| **⇧⌘J** | Skip the oldest skippable question. |
| **⌘↑ / ⌘↓** | Jump to the oldest/latest message. |
| **Page Up / Page Down** | Scroll a page. |
| **↑ / ↓** | Scroll when the composer is empty or its caret is at the corresponding boundary; otherwise move the caret. |
| **⌥⌘← / ⌥⌘→** | Narrow/widen the panel by 20 points. |
| **Tab / ⇧Tab**, then **Space** | Move between controls and activate the focused button. |
| **⌘,** | Open Settings. |

Except the two global shortcuts, these apply in the conversation panel. If your Talk shortcut already includes Shift, use **Ask About This** in the menu.

Drag the panel's edge to resize it. Width is saved and limited by the screen; **Reset width** is available in the panel and resize-handle context menus. With the handle focused, Left and Right also adjust the width.

Implementation references: [conversation model](../Zeus/Cards/ConversationModel.swift), [conversation view](../Zeus/Cards/ConversationView.swift), [attachment chips](../Zeus/Cards/AttachmentChip.swift), [attachment targets](../Zeus/Cards/AttachmentTarget.swift), [rating controls](../Zeus/Cards/MessageRatingViews.swift), [rating presentation](../Zeus/Cards/MessageRatingsModel.swift), [daily limit](../Zeus/Bridge/ZeusRuntime+Proactive.swift), [design and keyboard specification](design/CONVERSATION.md), and [contract §10](CONTRACT.md#10-conversation-model-v2-ux-decided-2026-10-11-replaces-the-card-stack-ux).
