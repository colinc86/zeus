# Setting up Zeus

[Documentation](README.md) · [Your assistant](ASSISTANT.md) · [Troubleshooting](TROUBLESHOOTING.md)

## 1. Install

Zeus needs macOS 26 or later. To let Zeus run your assistant, install **tmux** (`brew install tmux`) and at least one of the **Claude Code**, **Codex** or **OpenCode** command-line tools. Sign in to the agent, or configure its model provider, in Terminal first.

1. Download `Zeus-<version>.dmg` from [Releases](https://github.com/colinc86/zeus/releases/latest).
2. Open the disk image and drag **Zeus** into **Applications**.
3. Open Zeus. It appears on the desktop and in the menu bar, with no Dock icon.
4. Choose **Settings… › Assistant** from the menu bar or by right-clicking the character.

Click Zeus to open the conversation; drag it to move it. The default global shortcut is **⌥⌘Z**. If you turn off **Show menu bar icon** in General, right-click Zeus for the same menu. Reopening Zeus from Finder, Spotlight or Launchpad brings a hidden character back.

For a source build, see [Build and contribute](../README.md#build-and-contribute). Running a second copy of Zeus conflicts with the local bridge; quit the other copy before opening your build.

## 2. Let Zeus run your assistant (recommended)

In **Settings › Assistant**, choose **Zeus runs it**.

1. Choose an **Agent**. If a tool is missing, install it and press **Check Again**.
2. Choose a **Folder**, or press **Create one for me**. The latter creates an assistant folder, normally `~/Zeus Assistant`, with `AGENTS.md` and `CLAUDE.md`. Customize the instructions there for your work.
3. Choose **Permissions**. Defaults are **Ask first** for Claude Code, **Ask when needed** for Codex and **Ask** for OpenCode. Zeus asks for confirmation when you select an unrestricted mode.
4. Review **Instructions**. The caption tells you whether edits can apply by restarting the current conversation or require a new one.
5. Leave **Start when Zeus opens** on if you want Zeus to start the assistant on future launches.
6. Press **Start**. Answer any login or folder-trust prompt using **Open in Terminal**. The assistant is instructed to send a short greeting through Zeus.

Zeus runs the agent in a tmux session, usually called `zeus`. To attach yourself, press **Copy** next to the command in the status box and run that command in Terminal. It uses the actual session name, including a suffix when the name was already taken.

Zeus adds its MCP bridge and turn-completion reporting to that launch. It leaves your saved agent configuration intact. Quitting Zeus leaves the assistant running; Zeus reconnects next time. [Session controls, permissions and restarts](ASSISTANT.md) explains the lifecycle.

### Let your assistant control Zeus

Your assistant can change Zeus's appearance and install a Zeus update when requested. The switches are in **Settings › General**. [See the controls and their limits](CUSTOMIZATION.md#assistant-controls).

### Learn from me

Learning is optional and starts off. [Learn from me](LEARNING.md) explains the four levels, their permissions, retention and the journal.

#### The permissions Zeus asks for

See [permissions](LEARNING.md#permissions): Apps and timing needs none; Windows and pages uses Accessibility; Screen uses Screen Recording; Typing uses Input Monitoring and needs Apple Intelligence.

#### Apps and timing

[What Apps and timing keeps](LEARNING.md#apps-and-timing).

#### Windows and pages

[What Windows and pages keeps](LEARNING.md#windows-and-pages), including the Safari exception.

#### Screen

[When pictures are taken and how they are covered](LEARNING.md#screen).

#### Typing

[Chosen apps, typing topics and retained words](LEARNING.md#typing).

#### What your assistant can ask for

[Journal questions and assistant access](LEARNING.md#what-your-assistant-receives).

#### Ask About This

[Attach the window in front](LEARNING.md#ask-about-this).

#### What Zeus Kept

[Inspect, export and delete records](LEARNING.md#what-zeus-kept).

#### Rules

[The New rules dial and rules that act for you](LEARNING.md#rules).

## 3. Pick a character

Choose a character and its size in **Settings › Character**. Colors and fonts are in **Appearance**. [Characters and themes](CUSTOMIZATION.md) covers the built-ins, fading and imports.

### Make your own character

Use **Open Example** in **Settings › Character**, then save a copy with a new ID. [Follow the character guide](CUSTOMIZATION.md#make-your-own-character) and [sprite format](design/SPRITE_FORMAT.md).

### Themes

Use **Open Example** in **Settings › Appearance** to start a theme. [Follow the theme guide](CUSTOMIZATION.md#themes) and [theme format](design/THEME_FORMAT.md).

## 4. Connect your own session (advanced)

Choose **Connect your own** in **Settings › Assistant**. Zeus shows configuration and launch commands with the installed bridge path filled in. Run or copy these yourself: Zeus does not edit your agent's settings.

Use the **Start your agent** command from Settings when possible. It includes turn-completion reporting, so Zeus can stop its thinking indicator when the agent finishes without posting a Zeus message. The short commands below establish the connection but omit that hook.

The bundled bridge is `/Applications/Zeus.app/Contents/MacOS/zeus-mcp` for a standard installation. If you move Zeus, update the path in your MCP configuration.

### Claude Code

Add Zeus once, from your assistant's folder:

```sh
claude mcp add -s user zeus -- /Applications/Zeus.app/Contents/MacOS/zeus-mcp --agent claude
```

To use direct channel delivery:

```sh
claude --dangerously-load-development-channels server:zeus
```

Answer Claude's development-channel prompt in Terminal. The tested prompt offers **I am using this for local development**; Zeus never selects it for you. If channels are unavailable or you prefer Terminal delivery, run Claude inside tmux without that flag and choose **Its Terminal pane** in Settings. Keep the launch-only completion hook from the copied command.

Then choose the assistant session and ask Claude to say hello through Zeus. The managed **Zeus runs it** launch uses its Terminal pane and does not request a development channel.

### Codex

Add Zeus once:

```sh
codex mcp add zeus -- /Applications/Zeus.app/Contents/MacOS/zeus-mcp --agent codex
```

Start Codex in tmux from the folder where it should work:

```sh
tmux new-session -s codex codex --no-daemon -c 'mcp_servers.zeus.env_vars=["TMUX","TMUX_PANE"]'
```

Choose **Its Terminal pane**, select the pane running Codex and select its **Assistant session**. Press **Send Test Message**. A line beginning `[zeus delivery_id=…]` should arrive in Codex.

The environment override lets the MCP bridge identify the current tmux pane and socket. Zeus waits if the prompt contains unsent text.

### OpenCode

Merge this block into your assistant folder's `opencode.json`, or `~/.config/opencode/opencode.json` for all folders, preserving your other settings:

```json
{
  "mcp": {
    "zeus": {
      "type": "local",
      "command": ["/Applications/Zeus.app/Contents/MacOS/zeus-mcp", "--agent", "opencode"],
      "enabled": true
    }
  }
}
```

Start the OpenCode app with a fixed local port:

```sh
opencode --port 4096 --hostname 127.0.0.1
```

Use the app, not `opencode serve`. Set **Server URL** to `http://127.0.0.1:4096`, select the OpenCode **Assistant session**, then choose the **Conversation** that should receive messages. If you use `OPENCODE_SERVER_PASSWORD`, save it in Zeus's password field; Zeus keeps that copy in the Mac's Keychain.

Zeus delivers through the server, as a new message in the conversation you chose. It never types into OpenCode's prompt. If you change the server URL, choose the conversation again; Zeus does not silently move queued messages to another server.

### Session selection and launch hooks

With **Only my assistant**, Auto adopts the first eligible session of the chosen agent and keeps it until you change the selection or it ends. For direct delivery, that session must support the channel. With **Any session with the Zeus server**, Auto uses the newest eligible session; for Claude Code it prefers one Zeus can message directly.

The generated launch hooks leave saved configuration unchanged:

- Claude's hook is added through launch-only settings.
- Codex's `notify` override replaces a custom notifier for that launch. Omit the override if you need your own notifier.
- OpenCode's hook uses `OPENCODE_CONFIG_CONTENT`. If you already use that variable, merge the plugin configuration instead of overwriting it.

## 5. How your messages reach your assistant

Zeus saves outgoing messages before delivery. Answers return to the session that asked; messages you start go to the selected assistant. A disconnected earlier question can be handed to the current assistant. Acknowledgments stop retries; repeated delivery IDs tell the agent not to do the work twice.

[Routing and delivery](ASSISTANT.md#delivery-and-routing) covers all four transport choices and waiting messages.

### The status strip

The line above the message field explains what is waiting. Click it or press **⌘J** to go there. [Status strip and shortcuts](CONVERSATION.md#status-strip) explains the controls.

## 6. Troubleshooting

See [Troubleshooting and FAQ](TROUBLESHOOTING.md), including missing assistants, queued messages, permissions and hidden characters.

## Updates

Release builds check for Zeus updates daily by default. Choose **Check for Updates…** in the Zeus menu to check now. A scheduled update appears as **Update Available…**; select it to review the release notes and install.

**Settings › General › Automatically check for updates** controls the scheduled check. Debug builds never check. Your assistant's own updates and new Zeus tools use a separate [assistant restart](ASSISTANT.md#updates-and-instructions).
