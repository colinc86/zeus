# Troubleshooting and FAQ

[Documentation](README.md) · [Setup](SETUP.md) · [Settings](SETTINGS.md)

## Assistant and connection

| Symptom | Check or action |
|---|---|
| **Start** is disabled | Choose a folder and an installed agent in Assistant settings. Install tmux if requested, then press **Check Again**. |
| An installed agent is not detected | Press **Check Again**. Zeus searches common executable locations, including Homebrew and `~/.local/bin`. Make sure the CLI is installed, not only a separate desktop app. |
| **Waiting for you in Terminal** | Use the choices in a mirrored permission card, or **Open in Terminal** for login, folder trust or an unrecognized prompt. Messages wait until it clears. |
| **Couldn't keep it running** | Open Terminal, inspect why the agent exits, fix the agent's sign-in/configuration, then press **Try Again**. |
| No session appears with **Connect your own** | Check `claude mcp list`, `codex mcp list` or `opencode mcp list`. Verify the bridge path, then start a fresh agent session. |
| A tool says Zeus is not running | Open Zeus. If it is already open, check that you have not started two copies using the same bridge socket. |
| A tool says Zeus only talks to its assistant | Select that session in Assistant settings, or use the quiet notice's **Make it my assistant** action. **Any session with the Zeus server** broadens access deliberately. |
| Claude's direct channel does not deliver | Answer its channel prompt in Terminal. If the agent or organization does not allow channels, use tmux and **Its Terminal pane**. Managed mode already uses that route. |
| Codex's test message waits | Run Codex inside tmux with the command from Settings, choose its session and pane, and ensure the prompt is empty. |
| OpenCode's test message waits | Start the OpenCode app with the fixed port, not `opencode serve`; check Server URL, password and the selected **Conversation**. Re-select after changing the URL. |
| The character keeps thinking after a turn ends | Use the launch command from Settings for completion reporting. Explicit working statuses last until the assistant resets them or their TTL expires. Selected Terminal-pane sessions also have read-only completion detection. |

## Messages and learning delivery

| Symptom | Check or action |
|---|---|
| A message is queued | Read its caption. Zeus saves messages while the assistant is disconnected, busy, blocked, or has an unsent Terminal draft. |
| **Waiting on unsent text in Terminal** | Open Terminal and finish or remove your draft yourself. Zeus does not send or clear it. Cancel queued messages only if you no longer want them delivered. |
| **Message not delivered** or a red warning | Open **Delivery problem…**. Use the offered recovery action, **Retry Now** when appropriate, or **Discard…** to cancel after confirmation. |
| The same delivery appears twice | Retries are expected without acknowledgment. The agent should handle each delivery ID once and call `zeus_ack`; the assistant template explains this. |
| A summary stays ready; Sent is empty | Open **What Zeus Kept › Sent to your assistant**. **Waiting** gives the current reason and an action when one is available. Ready does not mean received. |
| New tools/instructions notice persists | Use **Restart assistant** at a convenient point. If you edited the template, compare through **Open Folder** or confirm **Use the new template…**. |
| A message arrives without a bubble or sound | Check quiet hours, whether Zeus is hidden, whether the conversation is open, active timing rules, and **Stop these** ratings. Sounds are off by default. |
| The assistant's answers appear only in Terminal | Ask it to reply through Zeus. New assistant folders contain instructions for using `zeus_say`, `zeus_ask` and `zeus_present`. |

## Attachments

| Symptom | Check or action |
|---|---|
| The assistant gets “Each file or folder attachment needs a summary…” and no message appears | It must supply a summary for every file/folder: 1–3 sentences, at least 20 non-whitespace characters, at most 400 total. One invalid attachment rejects the whole call. Correct it and retry; [MCP guidance](MCP.md#attachment-summaries) gives the exact error. This requirement does not apply to files you drop into the composer. |
| A summary is rejected as too long | Shorten it to 400 characters including whitespace. This limit also applies to optional link summaries. |
| There are no big Open or Finder buttons | Click the attachment chip to open it. Hover or focus an ordinary file/folder chip for **Show in Finder**, or right-click for available actions and **Copy Path**/**Copy Link**. Separate finished-work actions still appear as buttons. |
| No **More** under a summary | It appears only when the summary exceeds two lines in the conversation. A peek shows one line; open the conversation to read more. Older attachments and links may have no summary. |
| **Not found** | The file or folder is no longer at its saved path. Clicking reveals the nearest existing parent folder; ask the assistant for the current location. |
| An app or script opens Finder | Expected: Zeus reveals executable targets rather than running them. |
| **Can't be opened** | The saved target is invalid. Ask the assistant to send a valid absolute/`~` file path or HTTP(S) link. |
| An attachment edit through `zeus_update_card` fails | That tool only edits card text/title/progress; it preserves existing attachments and summaries. To share a corrected attachment, send a new message. |

[Attachment controls](CONVERSATION.md#attachments-from-your-assistant) · [Template updates](ASSISTANT.md#updates-and-instructions)

## Message ratings

| Symptom | Check or action |
|---|---|
| No **⋯** rating button | Hover an unprompted assistant message, question or finished-work card, or use **⌘R**. Replies, local/progress cards and older cards without origin metadata have no menu. A held card uses **Show** and **Change rating** instead. |
| **Neutral** messages still arrive normally | Expected: Neutral means **Only when I need to know**, judged by the assistant. It does not make messages quiet or hold them. |
| An urgent message was muted | **Stop these** also holds high-priority messages. Expand its **Muted: … › Show** row to inspect it. |
| Zeus muted the wrong kind | Choose **Not this kind** under the expanded message. This releases only that card, keeps the kind preference, and does not replay an alert. |
| A look-alike still gets through | Similarity is imperfect and depends on an installed language embedding. Check the label; an exact **More like this** or **Neutral** rating takes precedence over similarity to a stopped kind. Rate the new kind if appropriate. |
| Changing/removing a rating leaves an old message muted | Preferences govern new arrivals. Use **Show** to read a retained message; use **Not this kind** only when the match was wrong. |
| **Just this one** did not stop future messages | It sends feedback without a kind rule. Use **All of this kind** before choosing **Stop these** to stop the kind. |
| A single-message rating is absent from Settings or `preferences.md` | Those lists contain kind ratings only. Check the original message's rating row or the received delivery in **Sent to your assistant**. |
| Undo is no longer available | A later preference change invalidates the earlier Undo. Edit the current preference under **Settings › Rules › What you hear about**. |
| A rating has not reached the assistant | Open **What Zeus Kept › Sent to your assistant** and check **Waiting**. The saved confirmation is not a delivery receipt; a disconnected/busy assistant or an unsent Terminal draft can delay delivery. |
| Message preferences are locked or cannot be saved | Unlock the Mac/Keychain and retry. Zeus preserves existing preferences; failed edits are not silently saved in memory. If startup preferences cannot be read, unprompted tool posts wait for recovery. |
| Ratings still work with Learn from me off | Intentional. Explicit feedback, its delivery and the preferences file are independent of observation switches. |

[How to rate and inspect muted messages](CONVERSATION.md#rate-what-you-hear-about) · [Rating storage and delivery](PRIVACY.md#message-ratings-and-quiet-signals)

## Learn from me

| Symptom | Check or action |
|---|---|
| No activity is recorded | Enable **Let Zeus learn when and in what I work**. Check Pause for Today and the level's app scope. |
| Window titles are absent | Enable Windows and pages, grant Accessibility, and check the private/chosen-app lists. Browser context also needs a supported, permitted browser. |
| Safari details are absent | This is the default. Explicitly choosing Safari for a level permits details from its private windows too; read the caption before doing so. |
| No pictures are taken | Check Screen Recording and reopen when requested. Identical frames are skipped. Camera use, presentation/mirroring, secure input, private contexts and the hourly cap can stop capture. |
| Descriptions are simple or delayed | Apple Intelligence may be unavailable, or low power/battery conditions may have deferred descriptions. |
| Typing cannot be enabled | Apple Intelligence must be available. The disabled switch explains what is missing. |
| Typing is enabled but nothing is kept | Check Input Monitoring, reopen when asked, and add the app to the Typing list. Secure input, private contexts and unsupported input methods limit capture. |
| **Private input: Zeus isn't noting typing** | macOS secure input is active. Capture pauses until it clears. |
| Ask About This attaches nothing | Enable Windows and pages or Screen, grant its permission, and check the caption. Private or unavailable context is omitted; nothing is attached from a disabled level. |
| The journal/rules cannot be opened | Unlock the Keychain or sign in again. New records wait in memory; quitting before recovery loses unsaved records. |
| No observation files appear in the assistant folder | Enable a learning level and check **Settings › Privacy › Your assistant's folder**. Managed mode uses the working folder; Connect your own needs an explicit destination. |
| **Zeus can't write to this folder.** | Check that the selected folder is available and writable. The retained journal is separate. Choose an accessible destination to backfill retained records. |
| A file deleted in Finder does not return | Intentional: the export does not recreate files you removed. Finder deletion does not erase the internal journal or ratings; use What Zeus Kept for observations and Settings › Rules for kind ratings. |
| Pictures are not covered | Check **Cover pictures and faces**. The setting applies to new captures; turning it on does not modify earlier frames. |
| An old folder still has records after deletion | Retention and deletion apply to the current destination. A previous folder is left alone when you switch destinations. |
| No rules have been proposed | Learning needs relevant evidence and a delivered reflection. Evaluable rules require evidence across two days; the assistant may appropriately propose none. |
| A rule is only **Suggested** or **Waiting for your OK** | Turn it on or approve its shadow result in Rules. An unapproved acting rule is not permission to act. |
| A time trigger is rejected | Supply integer minutes 0–1439 for both `startMinute` and `endMinute`. If the client still advertises fractional bounds, refresh its tool discovery or restart it to load the current bridge schema. |

## Appearance and sound

| Symptom | Check or action |
|---|---|
| Zeus is hidden and the menu bar icon is off | Open Zeus from Spotlight, Launchpad or Finder, or use the Talk shortcut. |
| Zeus is off screen | **Settings › Character › Reset Avatar Position**. |
| Zeus stays asleep | Check **Settings › Assistant › Quiet hours**. Equal start/end hours mean all day. |
| A character or theme does not load | Read the validation error in Settings. IDs starting with `_` are skipped. See [customization](CUSTOMIZATION.md). |
| A custom theme is hard to read | Look for **Low contrast** and adjust its colors, or choose a bundled theme. |
| Conversation text is too small | Choose **Settings › Appearance › Text size › Large** or **Larger**. This applies immediately; Settings and menus keep the system size. Zeus does not follow macOS accessibility text size. |
| Two Pixel text sizes look the same | Pixel text grows in whole steps. **Small** changes titles; **Large** enlarges message text and buttons; **Larger** also enlarges captions such as summaries and the status line. See [fonts and text size](CUSTOMIZATION.md#fonts-and-text-size). |
| The Talk shortcut does not work | Record another combination in General. macOS-reserved or already registered combinations are refused. |
| No pop-up sound | Enable **Play a sound when Zeus pops up**, choose a sound, and check the Mac's alert volume. Quiet hours and an open conversation suppress it. |
| Update checks are unavailable | Debug builds disable updates. Use a release build for automatic checks and **Check for Updates…**. |

## FAQ

**Does Zeus include an AI model or agent account?**  
No assistant account is bundled. Install and configure Claude Code, Codex or OpenCode. Zeus uses Apple's on-device frameworks for learning redaction and descriptions.

**Must I enable learning?**  
No. Conversation, status, questions, attachments, message ratings and assistant management work with all learning levels off.

**Will quitting Zeus stop my assistant?**  
No. The managed tmux agent keeps running. Use **Stop** if you want it to stop.

**Does clearing the conversation erase the assistant's memory?**  
No. It clears eligible Zeus history, retaining pending items and message preferences. Starting a new assistant conversation and deleting learning records are separate actions. Agent files/provider history have their own lifecycle.

**Does Delete Everything delete rules?**  
It deletes the learning journal, summaries, Sent ledger, message ratings, corrections and quiet signals, empties `Zeus/` in the current assistant folder, and cancels pending rating deliveries and affected learning deliveries. **Also delete your assistant's notes** can additionally empty `Notes/`. Manage rules separately in **Settings › Rules**. It cannot retract data already received by the assistant.

**Can Undo reverse every action?**  
Rating Undo restores the preceding preference while no later edit has superseded it; it sends a new correction, not a recall. Appearance Undo is local to Zeus. A rule's Undo sends a reversal instruction to the assistant; whether the external action can actually be reversed depends on that action.

**Can several sessions talk to Zeus?**  
Choose **Any session with the Zeus server** under **Who may talk to Zeus**. The default admits only your selected assistant. Zeus manages only one assistant session itself.

**Why is there no Dock icon?**  
Zeus is a menu-bar application. Use the character, its right-click menu, the menu bar entry or the global Talk shortcut.
