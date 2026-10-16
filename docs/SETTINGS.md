# Settings reference

[Documentation](README.md) · [Setup](SETUP.md) · [Troubleshooting](TROUBLESHOOTING.md)

Open **Settings…** from the Zeus menu or press **⌘,** in the conversation. Defaults below describe a fresh installation; existing saved preferences are preserved. The window is resizable. General's jump row goes to Updates, Sounds, Shortcut or History.

## General

| Control | Default | Effect |
|---|---|---|
| **Automatically check for updates** | On in release builds | Checks daily. Unavailable in Debug builds. Version and build appear below it. |
| **Let my assistant control Zeus** | On | Enables supported app-control tools, including update checks. |
| **Let my assistant install updates** | On | Allows installation after a same-session update check. Disabled when the master control is off. |
| **Show menu bar icon** | On | Shows the menu bar entry. Right-clicking the character provides the same menu. |
| **Launch Zeus at login** | Off unless registered with macOS | Registers Zeus as a login item. macOS may require approval; **Open Login Items** goes to it. |
| **Enable global shortcut** | On | Enables the Talk shortcut. |
| **Talk shortcut** recorder | **⌥⌘Z** | Click and press a combination. Delete clears it; ↺ restores the default. Reserved or unavailable combinations leave the old shortcut in place. |
| **Play a sound when Zeus pops up** | Off | Adds a sound when a peek appears. Hidden Zeus, quiet hours and an open conversation suppress it. |
| **Sound** | Zeus chime | Zeus chime, Glass, Ping, Pop or Tink. Choosing one previews it at the Mac's alert volume. |
| **Typewriter reveal** | On | Reveals new message text progressively, once per card. |
| **Retro blip sound** | Off | Adds sound to typewriter reveal; disabled when reveal is off. Reduce Motion disables both effects. |
| **Clear Conversation…** | Action | Removes read/completed history after confirmation; preserves unread items, open questions/actions and unsent/unconfirmed messages. |
| **Retry Saving History** | Shown on a save error | Retries failed local history persistence. |

The Talk shortcut with Shift added opens **Ask About This**, unless the shortcut already contains Shift or the derived combination cannot register. The menu action remains available.

## Appearance

| Control | Default | Effect |
|---|---|---|
| **Theme** | Classic | Selects a built-in or imported theme. Classic follows macOS light/dark appearance. |
| **Import Theme…** | Action | Validates and installs a JSON theme, confirming a conflicting replacement. |
| **Open Example** | Action | Opens an annotated theme example. |
| **Open Themes Folder** | Action | Opens the user theme directory. |
| **Conversation font** | Pixel | Pixel (Departure Mono) or SF Mono. |

See [themes](CUSTOMIZATION.md#themes) for all seven built-ins, live reload and contrast behavior.

## Assistant

The setup choice defaults to **Zeus runs it**. **Who may talk to Zeus** and **Quiet hours** are shared by both modes.

### Zeus runs it

| Control | Default | Effect |
|---|---|---|
| Status panel | Off until configured | Shows lifecycle state and available **Start**, **Open in Terminal**, **Restart**, **Stop** or **Try Again** actions. |
| Attach command / **Copy** | No command before a session exists | Uses the actual tmux session name. |
| **Agent** | Claude Code if installed, otherwise the first available supported agent | Claude Code, Codex or OpenCode. Missing requirements are explained; **Check Again** refreshes them. |
| **Folder** / **Choose…** | None | Selects the agent's working folder. |
| **Create one for me** | Action | Creates a folder with assistant template instructions. |
| **Permissions** | Agent's asking mode | All modes and unrestricted confirmations are listed in [Your assistant](ASSISTANT.md#permission-modes). |
| **Instructions** | Zeus's built-in assistant launch instructions | Additional instructions; the caption explains whether changes apply on resume or at the next new conversation. |
| **Reset to Default** | Action | Restores those built-in launch instructions. |
| **Start a New Conversation** | Action | Asks before starting fresh. |
| **Start when Zeus opens** | On, usable once a folder is selected | Starts the configured assistant on app launch. |
| **Open Folder** / **Use the new template…** | Shown for an edited, outdated template | Opens the folder or asks before replacing template files and restarting. |

Changing agent/folder uses **Switch Now** or **Later**. A permission or supported instruction change waits for a safe restart. [Session controls](ASSISTANT.md#session-controls) explains the details.

### Connect your own

| Control | Default | Effect |
|---|---|---|
| **Agent** | Claude Code | Chooses the backend and its setup instructions. |
| **How Zeus reaches it** | Directly (recommended) for Claude; Its Terminal pane for Codex; OpenCode server for OpenCode | Also offers When it checks in. A saved explicit choice is retained. |
| **Assistant session** | Auto | Selects the destination for messages you initiate. Default admission pins the first eligible session; see [selection](SETUP.md#session-selection-and-launch-hooks). |
| **Terminal pane**, **Refresh**, manual target field | None | Appears for Terminal delivery. Selects a pane with its tmux socket namespace. |
| **Server URL** | `http://127.0.0.1:4096` | OpenCode endpoint; requires HTTP(S), with no embedded credentials. |
| Server password / **Save** / **Remove** | None | Saves/removes Zeus's copy in Keychain. |
| **Conversation** | None | Selects the exact OpenCode native conversation for server delivery. |
| Setup commands / **Copy** | Generated for the installed bridge | Configures and launches the agent when you run the commands. |
| **Read the full setup guide** | Collapsed | Expands the generated in-app instructions. |
| **Send Test Message** | Action | Sends through the selected route and reports the result. |

### Shared controls

| Control | Default | Effect |
|---|---|---|
| **Who may talk to Zeus** | Only my assistant | Alternative: Any session with the Zeus server. |
| **Quiet hours** | Off | Suppresses peeks and sounds during the selected local hours. |
| **From** / **Until** | 22:00 / 07:00 | Used when quiet hours are enabled. Equal hours mean all day. Questions and agent activity can still determine the character's pose. |

## Character

| Control | Default | Effect |
|---|---|---|
| Character picker | Zeus | Selects one of twelve bundled or user-imported characters. |
| **Size** | Medium | Small, Medium or Large. |
| **Import Character…** | Action | Validates, installs and selects a character file. |
| **Open Example** | Action | Opens the annotated character example. |
| **Open Characters Folder** | Action | Opens the user character directory. |
| **Reset Avatar Position** | Action | Restores the character's screen position. |
| **Fade Zeus when idle** | Off | Enables fading without making the character click-through. |
| **Idle opacity** | 30% | 10–90%; shown when fading is enabled. |
| **Fade after** | 30 seconds | 5 seconds–10 minutes; shown when fading is enabled. |

## Privacy

All observation switches start off. See [Learn from me](LEARNING.md) for collection rules, permission flows and the Safari exception.

| Level / control | Default | Choices or behavior |
|---|---|---|
| **Let Zeus learn when and in what I work** | Off | Apps and timing; one-time consent, no macOS permission. |
| **Let Zeus keep window titles and web addresses** | Off | Windows and pages; consent and Accessibility. |
| **Let Zeus look at the window in front now and then** | Off | Screen; consent and Screen Recording. |
| **Let Zeus keep what I type in apps I choose** | Off | Typing; consent, Apple Intelligence and Input Monitoring. |
| **Record in**, levels 1–3 | Everywhere except my private list | Alternative: Only in apps I choose. Lists are separate per level. |
| **Record in**, Typing | Only in apps I choose; empty list | No everywhere option. |
| Shared private list | Password managers, Keychain Access, Passwords, System Settings | **Add App…** and minus buttons edit it; the list wins at every level. |
| Chosen apps | Empty | **Add App…** and minus buttons edit that level's list. |
| **Keep activity for** | 90 days | 7, 14, 30, 60 or 90 days. Summaries: one year. |
| Windows and pages: **Keep for** | 90 days | 7, 30 or 90 days. |
| Screen: **Up to** | 12 an hour | 4, 12 or 30 pictures an hour. |
| **Keep descriptions for** | 90 days | 7, 30 or 90 days; pictures always expire after 7 days. |
| **Cover pictures and faces** | On | Covers private text and pixellates pictures/faces before storage. Turning off requires confirmation; detected secrets, card/account and identity numbers remain covered. |
| **Keep topics** | 30 days | 7, 30 or 90 days. |
| **Keep the words** | 24 hours | Don't keep, 24 hours or 7 days. |
| **Notes to your assistant** | All four moment types selected | First activity, back from a long break, later start, winding down. Up to four notes per day. |
| **Your assistant's folder** | Applied managed working folder; none in Connect your own | Shows the `Zeus/` record's path and write errors. |
| Folder **Show in Finder** | Action when configured | Opens the readable record. |
| Folder **Choose…** / **Stop keeping a folder** | Connect your own only | Chooses or stops the export destination; stopping leaves existing files alone. |
| Folder **Assistant Settings** | Managed mode with no folder | Opens Assistant settings to choose the working folder. |
| **What Zeus has recorded** | Empty until recording | Today's activity list. |
| **Open What Zeus Kept…** | Action | Opens stored records and the Sent ledger. |
| **Pause for Today** / **Resume** | Not paused | Stops observation until midnight, or resumes sooner. |
| **Delete Everything…** | Action | Confirms deletion of the journal, summaries and Sent ledger, empties the active `Zeus/` folder, and cancels affected pending deliveries. **Also delete your assistant's notes** starts off; selecting it also empties `Notes/`. Rules remain separately managed. |

## Rules

Visible when any learning level is enabled or rules exist.

| Control | Default | Effect |
|---|---|---|
| **New rules** | Balanced | Ask me first, Balanced or Just do it; acting rules still need the implemented shadow approval. |
| **Active** | Empty | Enabled rules, with on/off toggles. |
| **Waiting for your OK** | Empty | Shadow rules, with **OK** and **Not This**. |
| **Suggested** | Empty | Proposed rules, with **Turn On** and **Dismiss**. |
| **Show … retired** / **Hide retired** | Retired section collapsed | Reveals retired rules and **Turn Back On**. |
| Rule **…** menu | Action | **Why?**, **Edit…**, **Delete**. Deletion offers Undo. |
| **Add Rule…** | Action | Creates a passive rule with a sentence, days, start/end time, apps and state. |

The editor offers **Choose App…** and **Remove** for apps, **Any**, **Tests failing** or **In a meeting** for state, and **Save**/**Cancel**. Leave time/day constraints empty for any time. Triggers combine; an unknown state does not match. See [rules](LEARNING.md#rules) for approval and confidence behavior.

## About

Shows the app icon, version and build, description and basic interaction hints. There are no preferences in this pane.

Implementation references: [app defaults](../Zeus/Settings/AppSettings.swift), [General](../Zeus/Settings/GeneralSettingsView.swift), [assistant](../Zeus/Settings/AssistantSettingsView.swift), [connection options](../Zeus/Settings/AgentSettingsView.swift), [learning defaults](../Zeus/Learn/LearnSettings.swift), [observation defaults](../Zeus/Settings/ObservationSettings.swift), and [Rules](../Zeus/Settings/RulesSettingsView.swift).
