# Your assistant

[Documentation](README.md) · [Set up an assistant](SETUP.md) · [Settings reference](SETTINGS.md#assistant)

## Two ways to connect

| Mode | Who starts it | How Zeus reaches it |
|---|---|---|
| **Zeus runs it** | Zeus starts and maintains one assistant in tmux. | Its owned Terminal pane; a confirmed Claude channel can be used when available. |
| **Connect your own** | You start and manage the agent. | The route you select: direct Claude channel, a tmux pane, OpenCode's server or polling. |

The managed mode is selected on first run. It requires tmux and an installed agent CLI. **Connect your own** preserves control of your existing setup and provides commands for adding Zeus yourself.

Zeus injects its bridge and instructions into managed launches. Your agent's saved configuration, MCP servers, plugins and folder instructions still apply.

## The assistant folder

The folder is the agent's working directory. **Choose…** selects an existing folder. **Create one for me** creates a new assistant folder with instructions for speaking through Zeus, acknowledging deliveries and using learning tools.

You can edit its `AGENTS.md` and `CLAUDE.md`. The built-in **Instructions** field supplies additional launch instructions; it does not replace those files. A new conversation receives a short first message asking the agent to check in.

## Session controls

| Control | Effect |
|---|---|
| **Start** | Starts the configured assistant, or resumes its saved conversation when available. |
| **Open in Terminal** | Opens the actual managed tmux pane so you can inspect it or answer a prompt. |
| **Copy** beside the attach command | Copies a command for the actual session; use this instead of assuming its name. |
| **Restart** | Restarts the agent while preserving its native conversation when it can be resumed. |
| **Stop** | Stops the pane Zeus owns. Panes you added yourself are left alone. |
| **Start a New Conversation** | Asks for confirmation, then starts fresh with the current instructions. |
| **Try Again** | Retries after Zeus stopped restarting an agent that repeatedly quit. |

The session is normally named `zeus`; Zeus uses a suffix if that name belongs to another session. Quitting Zeus leaves its agent running. Opening Zeus again reconnects to the owned session.

An unexpected exit triggers restarts with backoff. After repeated failures within ten minutes, Zeus stops trying and shows **Couldn't keep it running**. A clean exit, such as `/exit`, leaves the agent stopped until you start it.

Switching to **Connect your own** while the managed agent is running asks **Stop the Zeus-run agent?**. **Stop** ends it; **Keep Running** switches modes and leaves that session running.

## Permission modes

These are the modes Zeus offers for a managed launch. They configure the agent's behavior; Zeus never makes its prompt decisions for you.

| Agent | Mode | Behavior |
|---|---|---|
| Claude Code | **Ask first** (default) | Asks before editing files or running commands. |
| Claude Code | **Plan only** | Inspects and proposes a plan; asks before acting. |
| Claude Code | **Never ask** | Does what is already allowed and refuses the rest. |
| Claude Code | **Accept edits** | Edits without asking; asks before other commands. |
| Claude Code | **Auto** | Uses the agent's safety check for routine actions; some models fall back to Ask first. |
| Claude Code | **Bypass permissions** | Can run commands and change files without asking. |
| Codex | **Ask when needed** (default) | Works in the chosen folder; asks before going outside it. |
| Codex | **Read only** | Reads files; asks before doing more. |
| Codex | **Approve for me** | Works in the folder with a safety check answering requests. |
| Codex | **Full access** | Has no sandbox; still asks before risky commands. |
| Codex | **YOLO** | Has neither sandbox restrictions nor approval prompts. |
| OpenCode | **Ask** (default) | Asks before tools you have not allowed. |
| OpenCode | **Deny** | Refuses tools you have not allowed. |
| OpenCode | **Allow all** | Uses tools you have not denied without asking. |
| OpenCode | **Auto** | Approves requests itself; tools you denied remain denied. |

Modes marked **Unrestricted** require confirmation in Zeus. Logins and folder-trust prompts always wait for you in Terminal.

When Zeus recognizes a managed permission question, it shows the agent's own choices in the conversation. Clicking a choice causes Zeus to recheck that the same prompt is still present before sending that choice. If it cannot read or validate the prompt, use **Open in Terminal**. Messages wait while the agent is blocked.

## Changing settings while running

A permission-mode change applies at a safe moment by restarting the same conversation. Zeus waits for the agent to be idle, with no draft, blocking prompt or delivery in flight.

Instruction edits also use restart-and-resume when the agent supports updated instructions on resume. Codex currently needs a new conversation for those edits. Claude support depends on the installed CLI's resume capabilities. The caption under **Instructions** states which behavior applies.

Changing the agent or folder asks **Switch Now** or **Later** because the switch starts a new conversation. Changing **Start when Zeus opens** does not restart the running assistant.

## Updates and instructions

There are three separate update paths:

- **Zeus updates:** the app's updater installs a release and relaunches Zeus. The tmux assistant can keep running.
- **Agent updates:** when the managed agent reports an installed update awaiting restart, Zeus offers **Restart assistant**. Clicking it requests a safe restart of the same conversation.
- **New Zeus tools or template instructions:** after a Zeus update, a quiet notice and Settings can offer a restart to load them. Zeus refreshes template files only when they still exactly match a shipped template. Edited files are preserved; **Open Folder** lets you compare, and **Use the new template…** asks before replacing them.

An update notice alone does not restart the assistant. Unrestricted modes retain their confirmation.

## Delivery and routing

| **How Zeus reaches it** | Transport |
|---|---|
| **Directly (recommended)** | Claude Code's Zeus channel. |
| **Its Terminal pane** | A checked, bracketed paste into the selected tmux pane, then submission. |
| **OpenCode server** | A new message in the specifically selected native conversation. |
| **When it checks in** | Saved messages returned when the agent calls `zeus_get_responses`. |

Answers normally return to the session that asked. Messages you initiate go to your chosen assistant. If an earlier question's session remains disconnected, Zeus can reroute its answer to the current assistant with an earlier-session explanation.

Zeus saves deliveries and requires acknowledgment. Unacknowledged messages can repeat with backoff (3, 6, 12 and 24 minutes); the agent must deduplicate by delivery ID. Successful transport alone does not prove the agent handled a message.

For Terminal delivery, Zeus checks the input before pasting and before submission. It does not intentionally clear or send a human draft. If a draft is present or the prompt is uncertain, the message waits. tmux cannot make its final screen check and Enter key atomic; this is a transport limitation.

**Delivery problem…** opens the waiting deliveries and recovery controls. **Discard…** asks before cancelling them. A summary or reflection held for ten minutes also gets an explanatory line; the learning ledger shows prepared items under **Waiting**.

## Who may talk to Zeus

The default is **Only my assistant**. In managed mode, this is the session Zeus owns. In **Connect your own**, it is the session you selected, or the first eligible session Auto adopted. Later sessions do not take over automatically.

A refused session cannot post into your conversation or read Zeus's state. A quiet notice lets you change the assistant or ignore the attempt. **Any session with the Zeus server** allows multiple sessions to post, while the selected assistant remains the destination for messages you initiate.

Implementation references: [managed runtime](../Zeus/Agents/ManagedSessionController.swift), [settings model](../Zeus/Settings/ManagedAssistantModel.swift), [launch policies](../Zeus/Agents/ManagedAgentLaunch.swift), [admission and tool routing](../Zeus/Bridge/ZeusRuntime+Tools.swift), and [contract §5 and §11](CONTRACT.md).
