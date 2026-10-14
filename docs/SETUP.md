# Setting up Zeus

Zeus is a small animated character on your desktop that acts as the face of your AI assistant (Claude Code, Codex or OpenCode). It shows the assistant's messages, asks you its questions and hands you finished work. Zeus can run the assistant for you, so setup is: pick an agent, pick a folder, press Start.

## 1. Install

1. Open the Zeus disk image and drag **Zeus** into **Applications**.
2. Open Zeus. It lives in the **menu bar** (⚡) and has no Dock icon. The character appears on your desktop:
   - **Click** it to open the conversation;
   - **drag** it anywhere (it remembers where you put it);
   - **right-click** it for quick controls: Talk to Zeus, Settings, Character, Size, Hide.
3. Open **Settings → Assistant** from the menu bar (⚡ → **Settings…**, or ⌘,).

**Building from source** needs macOS 26, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```sh
git clone <this repo> Zeus && cd Zeus
scripts/build.sh
ditto build/DerivedData/Build/Products/Debug/Zeus.app /Applications/Zeus.app
open /Applications/Zeus.app
```

## 2. Let Zeus run your assistant (recommended)

In **Settings → Assistant**, choose **Zeus runs it**. Zeus starts the agent in Terminal for you (in a tmux session, usually called `zeus`), keeps it running, and adds itself to that launch only. Your own agent settings, MCP servers and instructions still apply, and Zeus never edits them.

**Before you start**
- Install **tmux** (`brew install tmux`) and your agent's command-line tool.
- Sign in to the agent once in Terminal. Zeus never signs in or accepts prompts for you.

**Then, top to bottom:**
1. **Agent:** Claude Code, Codex or OpenCode. Agents that aren't installed say what's missing; install one, then press **Check Again**.
2. **Folder:** where your assistant works and keeps its notes. Choose one, or press **Create one for me** for a new `Zeus Assistant` folder in your home folder. It comes with an `AGENTS.md` that teaches the assistant how to be Zeus. Open it and fill in the short section about you at the bottom.
3. **Permissions:** the agent's own modes, explained in one line each. **Ask first** (Claude Code), **Ask when needed** (Codex) and **Ask** (OpenCode) are the defaults: the agent asks before doing anything risky. Modes marked **Unrestricted** let it run any command without asking, and Zeus asks you to confirm before using one.
4. **Instructions:** what the assistant is told every time it starts. The default is a good start; **Reset to Default** brings it back. Changes apply to the next new conversation.
5. **Start when Zeus opens:** on by default once you've chosen a folder.
6. Press **Start**. The assistant checks in with a short hello in the conversation.

**While it runs**
- The status box at the top says what it's doing: Running, Working, Waiting for you in Terminal, and so on. The menu bar shows the same thing when it needs you.
- **Watch it or type to it** in Terminal: press **Open in Terminal**, or press **Copy** next to the command in the status box and run it yourself. Use that command rather than typing the name yourself: if another tmux session already has that name, Zeus picks another (`zeus-2`), and the command always shows the right one, such as `tmux attach -t =zeus-2`.
- **When it needs you in Terminal** (a sign-in, a folder-trust question or a permission prompt), Zeus shows a gold card, *"Claude Code is waiting for you in Terminal"*, with an **Open in Terminal** button. Answer the prompt there. Zeus holds your messages until you have, and the card closes by itself.
- **If it quits unexpectedly**, Zeus restarts it and picks up the same conversation. After 5 quits in 10 minutes it stops trying and says so; press **Try Again** when you're ready.
- **If you type `/exit`**, it stays stopped until you press **Start**.
- **Quitting Zeus leaves the assistant running.** Zeus reconnects to it next time it opens.
- **Claude Code messages use its Terminal pane.** Zeus's tools are allowed for this launch only, while the permission mode you chose still governs other work. The managed launch skips the development-channel flag: Claude Code 2.1.296 cannot register a channel from the launch-only MCP configuration. Your global and project configuration stays intact.
- **Start a New Conversation** gives the assistant a fresh start with your current instructions.

## 3. Pick a character

**Settings → Character**:
- Pick one of 12 characters: Zeus, Wisp, Jack, Gizmo, Sprout, Merlo, Midnight, Bones, Gloop, Nyx, Hoot or Spore.
- **Size** (Small, Medium or Large) sets how big it draws.
- **Reset Avatar Position** brings it back if it's ever off screen.

Your assistant can also change the costume when you ask it to.

**Your own characters:** drop a character JSON file into `~/Library/Application Support/Zeus/Characters/`. A file with the same `id` replaces a built-in one. The format is in [design/SPRITE_FORMAT.md](design/SPRITE_FORMAT.md). Check your file with:

```sh
swift run --package-path Packages/ZeusKit zeus-sprites validate ~/Library/Application\ Support/Zeus/Characters
```

## 4. Connect your own session (advanced)

Use this if you'd rather start the agent yourself, or keep a setup you already have. In **Settings → Assistant**, choose **Connect your own**. The pane shows each step with the commands ready to copy, with your Zeus path already filled in.

Zeus ships a small bridge, `zeus-mcp`, inside the app. You add it to your agent once; each agent session then starts its own copy, so replies go back to the session that asked. If you move `Zeus.app`, add it again with the new path.

The pane has:
- **Agent:** Claude Code, Codex or OpenCode.
- **How Zeus reaches it:** how your messages and answers get to the agent (§5). It's chosen for you per agent.
- **Assistant session:** which session gets the messages *you* start. **Auto** picks your newest session of the chosen agent; for Claude Code it prefers one Zeus can message directly. The picker shows which session Auto picked. Choose a session yourself to keep it fixed.
- **Send Test Message**, to check the whole path.

### Claude Code

1. Add Zeus (once), from your assistant's folder:
   ```sh
   claude mcp add -s user zeus -- /Applications/Zeus.app/Contents/MacOS/zeus-mcp --agent claude
   ```
2. Start Claude Code like this:
   ```sh
   claude --dangerously-load-development-channels server:zeus
   ```
   The flag only lets Claude Code receive your Zeus messages directly. Each launch shows **WARNING: Loading development channels**: choose **I am using this for local development** (option 1) in Terminal. If you decline, Zeus still works, but your messages wait until Claude checks in with Zeus. The managed **Zeus runs it** path uses its Terminal pane instead and skips this warning.
3. Ask Claude: *"Say hi through Zeus."*

On a Team or Enterprise plan, an admin may need to allow channels (the `channelsEnabled` setting).

### Codex

Codex can't receive messages directly, so Zeus **types them into Codex's Terminal pane**. Run Codex inside tmux.

1. Add Zeus (once):
   ```sh
   codex mcp add zeus -- /Applications/Zeus.app/Contents/MacOS/zeus-mcp --agent codex
   ```
2. Start Codex in tmux, from your assistant's folder:
   ```sh
   tmux new-session -s codex codex
   ```
3. In Settings, set **How Zeus reaches it** to **Its Terminal pane**, pick the pane running Codex (or type one, such as `%3`), and choose its **Assistant session**.
4. Press **Send Test Message**. A line starting `[zeus delivery_id=…]` appears in Codex and is submitted.

Zeus never types over text you haven't sent: if the Codex prompt has a draft in it, your message waits.

### OpenCode

Zeus sends each message straight to the OpenCode **conversation** you choose, through the running OpenCode app's local server. It never types into OpenCode's prompt, so a draft you're writing there is left alone.

1. Add the Zeus block (shown in Settings) to `opencode.json` in your assistant's folder, or to `~/.config/opencode/opencode.json` for every folder. Keep your other settings.
2. Start OpenCode on a fixed local port:
   ```sh
   opencode --port 4096 --hostname 127.0.0.1
   ```
   Use the OpenCode app itself, not `opencode serve`.
3. In Settings, set the **Server URL** to `http://127.0.0.1:4096`, choose OpenCode under **Assistant session**, then choose the **Conversation** that should get your messages.
4. If your server has a password (`OPENCODE_SERVER_PASSWORD`), save it in the password field. It's kept in your Mac's Keychain.

If you change the server URL later, choose the conversation again. Zeus never moves your messages to a different server by itself.

## 5. How your messages reach your assistant

When you answer a question or type a message, Zeus saves it before sending anything, so nothing is lost if the agent or Zeus restarts.

- **An answer to a question** goes to the session that asked it.
- **A message you start** goes to your assistant: the one Zeus runs, or the Assistant session you chose.

| How Zeus reaches it | Used for | What the agent sees |
|---|---|---|
| **Directly** | Claude Code with Zeus's channel | the message, in the conversation |
| **Its Terminal pane** | Codex, or any agent in tmux | a typed line starting `[zeus delivery_id=…]` |
| **OpenCode server** | OpenCode | the same line, as a new message in the conversation you chose |
| **When it checks in** | anything | nothing until the agent asks Zeus for new messages |

**Confirmations and retries**
- The agent confirms each message it has handled. The instructions in `AGENTS.md` teach it to.
- Without a confirmation, Zeus sends the message again after 3, 6, 12 and 24 minutes. The agent ignores repeats it has already handled.
- A message for a session that's away waits, and goes out when it's back.

**When something's stuck**, the character shows a red "!" and the menu says *"Couldn't reach your assistant. Zeus will keep trying."* Choose **Delivery problem…** to see what's waiting and to **Retry Now** or **Discard**. Nothing is thrown away until you discard it.

## 6. Troubleshooting

| What you see | What to do |
|---|---|
| The status box says **Waiting for you in Terminal** | Press **Open in Terminal** and answer the prompt there (a sign-in, a folder-trust question or a permission). |
| The status box says **Couldn't keep it running** | Press **Open in Terminal** to see why it quit (often a sign-in or a missing model setting), fix it, then **Try Again**. |
| An agent says it isn't installed | Install it, then press **Check Again**. Zeus looks in the usual places, such as `/opt/homebrew/bin` and `~/.local/bin`. |
| The menu says **No assistant connected** (Connect your own) | Run `claude mcp list` (or `codex mcp list`, `opencode mcp list`) and check that zeus is connected. Start a new agent session after adding it. |
| Claude gets your messages late (Connect your own) | Start it with `--dangerously-load-development-channels server:zeus` and choose **Yes** when it asks. On Team or Enterprise, ask your admin about `channelsEnabled`. |
| **Send Test Message** says it's waiting, for Codex or OpenCode | Choose that session under **Assistant session**, and check **How Zeus reaches it**. |
| A message appears in the agent twice | That's a retry: the agent didn't confirm it. Make sure it reads the `AGENTS.md` from Zeus's folder template. |
| A tool says *"Zeus app isn't running"* | Open Zeus. It reconnects by itself. |
| The character is gone | ⚡ → **Show Zeus**. If it's off screen: Settings → Character → **Reset Avatar Position**. |
| Zeus looks asleep all day | Settings → Assistant → **Quiet hours**. Equal start and end times mean *all day*. |
| My own character doesn't show up | Run `zeus-sprites validate` on your folder (§3). Files with errors are skipped. |
| The assistant posts too often or too rarely | Edit "When to reach out" in your assistant folder's `AGENTS.md`. It's yours to tune. |

## Updates

Release builds check for updates once a day. Choose **Check for Updates…** in the
Zeus menu to check now. A scheduled update appears quietly as **Update Available…**;
select it to see the release notes and install. Settings → General has
**Automatically check for updates**, with the current version and build below it.
Debug builds never check for updates.
