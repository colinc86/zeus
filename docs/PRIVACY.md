# Privacy and security

[Documentation](README.md) · [Learn from me](LEARNING.md) · [Assistant permissions](ASSISTANT.md#permission-modes)

Zeus processes observations and redaction on your Mac. Learning starts off, with a separate opt-in for each level. The Privacy pane explains: “Zeus never sends your data anywhere itself. Your assistant reads its folder and what Zeus sends it. Where that goes depends on the assistant you chose.” Local collection does not mean the assistant's processing is local.

## What is collected

[Learn from me](LEARNING.md) describes the exact scope of each level. Apps and timing keeps activity metadata. Windows and pages adds titles and document/page references. Screen adds occasional front-window pictures. Typing adds topics and optionally retained redacted words from chosen apps.

Zeus does not collect microphone audio, camera images, location, or clipboard contents as part of learning. The screen observer checks whether a camera is in use without opening it. The typing observer notes a paste without reading its contents. Files, text and pictures you deliberately drop into the conversation are ordinary attachments and are not added to the learning journal.

The shared private app list always wins over a level's chosen-app list. Detailed capture stops for secure input, the lock screen and excluded/private contexts. Browser privacy relies on what the browser can report. **Safari details are excluded by default, but explicitly choosing Safari for a level also permits its private windows.** See [scope and private windows](LEARNING.md#app-scope-and-private-windows).

## Redaction before storage

The text pipeline runs before a learning record is stored:

1. Fixed patterns identify formats such as email addresses, payment-card numbers, IBANs, identity numbers, passwords and keys.
2. Apple's `NSDataDetector` detects phone numbers and addresses; NaturalLanguage name tagging identifies personal names.
3. When available, Apple's on-device Foundation Model checks the remaining prose for names, health, finance and secrets. It can remove matching text; it does not reconstruct missing details.

Removed spans become typed placeholders such as `‹name›`, `‹email›` or `‹secret›`. The viewer and the assistant receive the retained form. If the model is unavailable or does not complete, the always-available pattern/detector/name pass remains; Typing cannot be enabled without model availability. No redaction request uses Private Cloud Compute or an external model service.

For pictures, Vision reads text and detects faces and likely picture regions. With **Cover pictures and faces** on (the default), Zeus covers detected private text and pixellates detected picture regions and faces before encoding the stored frame. Turning it off requires confirmation and leaves pictures, faces and ordinary text uncovered in new frames. Detected passwords, keys, card/account numbers and identity numbers are still covered. Existing frames are unchanged. Password dialogs and other guarded contexts are dropped. Descriptions are generated from the filtered text and metadata. Detection is not a guarantee that every private detail or picture is found; **What Zeus Kept** shows the actual retained result.

## Storage on the Mac

Zeus's internal application data is under `~/Library/Application Support/Zeus/`.

| Data | Storage and control |
|---|---|
| Learning journal and stored frames | Encrypted on disk with a key held in the Mac's Keychain. Inspect and delete through What Zeus Kept. |
| Assistant-folder record | Readable Markdown and JPEG files under `Zeus/` in the chosen folder; not encrypted by Zeus. Written with owner-only permissions. The folder's sync/backup behavior applies. |
| Rules and outcomes | Persisted in the encrypted rules store; manage rules in Settings › Rules. |
| Conversation cards and delivery queue | Local JSON files, including messages and attachments. These are separate from the encrypted learning journal. Clear read/completed conversation history in General. |
| User characters and themes | Editable JSON in `Characters/` and `Themes/`. |
| OpenCode server password saved in Zeus | Keychain, not the server URL or plain preferences. |
| Assistant conversation and files | Owned by the chosen agent and its working folder; Zeus's learning deletion is not an agent-history eraser. |

An unavailable Keychain leaves new journal/rules writes queued in memory. The Privacy pane reports this; they are saved when access returns. Unsaved records are lost if Zeus quits first.

Retention and deletion update the active assistant-folder record. Changing folders leaves the earlier copy alone. Finder deletion prevents that exported file from being recreated, but does not delete its journal source. **Delete Everything…** empties the current `Zeus/`; its unchecked **Also delete your assistant's notes** option additionally empties `Notes/`. Other assistant working files are unaffected.

Viewer exports and copies in previous destinations are separate files. Removing journal records cannot remove those copies or retract material already received by an assistant.

## What the assistant can read

By default, summaries and reflections carry redacted descriptions and topics. The journal tool returns permitted activity descriptions, titles, screen descriptions and typing topics. Its `raw: true` option includes retained pictures or words from enabled levels. There are no separate picture/word-access switches. Here, “raw” means the stored form after capture safeguards and the chosen picture-covering setting.

The assistant can also read the retained record in its folder without making a journal-tool call. This includes pictures and retained words. It may keep its own dated conclusions in `Notes/`, which Zeus does not read or update.

**Sent to your assistant** records consumed learning/context deliveries and exact journal answers. A queued attempt appears separately under **Waiting**. It is a record of delivery, not an audit of the assistant's model-provider traffic or its independent file reads.

Your assistant can send received material to its configured model provider like any other message. The template instructs it to use learning for relevant help, not to reconstruct placeholders or repeat private details unprompted. These instructions do not change the agent's own provider or permissions.

## The bridge and session boundary

The bundled `zeus-mcp` bridge communicates with Zeus through a local Unix socket restricted to the user. The default **Who may talk to Zeus › Only my assistant** admits the selected or managed assistant. Other connected sessions receive a refusal instead of posting into your thread or reading Zeus state. A former assistant may still collect or acknowledge deliveries already addressed to it.

This is a session-routing boundary, not isolation from programs running with your macOS account's permissions. **Any session with the Zeus server** deliberately broadens admission.

OpenCode's server route uses the URL and native conversation you select. Localhost is the default. A changed URL needs a new conversation selection, and Zeus does not place passwords into URLs.

## Actions and permission prompts

Zeus never edits your saved agent configuration, MCP settings or agent credentials. Managed integration is added per launch; with **Connect your own**, you run the setup commands yourself.

Zeus never auto-accepts a native agent prompt. A permission answer in the conversation is your explicit click, revalidated against the current prompt. The permission mode you select can separately allow the agent to act without asking.

App-control tools cannot change the agent's authority, enable learning, erase your history or answer the agent's prompts. Rule tools propose rules and record outcomes; they do not execute external actions. Purchases require a new amount-bearing approval every time. See [assistant controls](CUSTOMIZATION.md#assistant-controls) and [rules](LEARNING.md#rules).

Zeus itself also uses the network for release update checks/downloads and for a configured OpenCode server connection. Its local-learning design is not a claim that the entire application never makes network requests.

Implementation references: [redactor](../Zeus/Learn/Redactor/LocalRedactor.swift), [on-device prose pass](../Zeus/Learn/Redactor/OnDeviceProseRedactor.swift), [frame redactor](../Zeus/Learn/Screen/FrameRedactor.swift), [encrypted journal](../Zeus/Learn/Journal/EncryptedJournalStore.swift), and [admission](../Zeus/Bridge/ZeusRuntime+Tools.swift).
