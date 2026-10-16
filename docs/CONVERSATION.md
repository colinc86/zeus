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

## Cards and history

| Item | What it shows |
|---|---|
| Message | An assistant update or reply, with formatted text and links. |
| Question | Choices, a text reply target, or both. |
| Finished work | A title, summary, attachments and optional actions. |
| Progress | An update in place, with a progress bar when supplied. |
| Activity | A thinking or working indicator while the assistant responds. |
| Notice | A quiet line for an app change, learning receipt, rule or restart. |

Attachments stay available in older messages. Files and folders open in their usual apps or Finder; links open through macOS. Zeus does not execute attachment targets as commands.

New messages follow the thread when you are at the bottom. If you scroll back, new arrivals leave your place alone and show a jump-to-latest control. Sending a message returns you to the newest part of the conversation.

History is saved locally. Zeus retains the newest 500 history cards plus pending or unsaved outgoing messages. **Clear Conversation…** asks first and preserves unread messages, open questions and actions, and unsent or unconfirmed messages. It does not clear the learning journal or reset the assistant's native conversation.

## Attach things

Drag files, folders, images, text or links onto Zeus. The conversation opens with removable attachment chips. Nothing is sent until you press **Send**, and attachments can be sent without text.

A dropped folder offers **Work in this folder** when Zeus runs the assistant. This uses the normal folder-switch confirmation and starts a new assistant conversation.

Dropped material is not added to Learn from me. To attach context from the current window with the learning safeguards applied, use [Ask About This](LEARNING.md#ask-about-this).

## Speech bubbles (peeks)

When the conversation is closed, a new message, question or finished-work card can appear as a small bubble beside Zeus. It does not take keyboard focus. Click the bubble to open the full conversation; up to three choices can be answered directly in it.

Ordinary peeks disappear after a reading interval of 6–15 seconds, with the timer paused while you hover. High-priority peeks wait for interaction. New arrivals replace the current peek and show how many more messages are waiting. Status and progress updates do not create peeks.

Quiet hours and hiding suppress peeks and sounds. Active timing rules can hold routine peeks while still keeping the cards and unread badge. High-priority cards bypass a rule hold, but do not override an explicit hide or quiet hours. A peek that times out without interaction leaves its message unread.

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
| **Return** | Send the message. |
| **⇧Return** or **⌥Return** | Insert a line break. |
| **Escape** | Close the current popover or conversation. |
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

Implementation references: [conversation model](../Zeus/Cards/ConversationModel.swift), [conversation view](../Zeus/Cards/ConversationView.swift), [design and keyboard specification](design/CONVERSATION.md), and [contract §10](CONTRACT.md#10-conversation-model-v2-ux-decided-2026-10-11-replaces-the-card-stack-ux).
