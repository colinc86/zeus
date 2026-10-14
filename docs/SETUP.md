# Setting up Zeus

Zeus is a small animated character on your desktop that acts as the face of your AI assistant (Claude Code, Codex or OpenCode). It shows the assistant's messages, asks you its questions and hands you finished work. Zeus can run the assistant for you, so setup is: pick an agent, pick a folder, press Start.

## 1. Install

1. Open the Zeus disk image and drag **Zeus** into **Applications**.
2. Open Zeus. It lives in the **menu bar** (⚡) and has no Dock icon. The character appears on your desktop:
   - **Click** it to open the conversation (drag the panel's edge to make it wider);
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

### Let your assistant control Zeus

Ask your assistant to change Zeus and it can: switch the character or theme, make a new one from your description, move Zeus, change its size, hide it for a while (1 minute to 12 hours, or until tomorrow) and change the appearance settings. Each change adds one line to the conversation with a single button, **Undo** (or **Show now** after a hide), for example *Added Pixel Cat · Undo*. Undoing a new character or theme switches back but keeps the file.

It never changes its own authority. It can't answer, dismiss or pick an option in any prompt; change its permission mode, instructions, agent, folder or run mode; start, stop or restart itself; clear the conversation; turn on launch at login, Learn from me or automatic update checks; or touch your agent's configuration. It also can't turn quiet hours off while a question is waiting for you.

It can check for updates and, when you ask, install one. Zeus says *"Updating to 0.1.9 — back in a few seconds"* first, and your assistant keeps running through the relaunch.

**Settings → General** has two switches, both on by default:
- **Let my assistant control Zeus**: off, and every change is refused.
- **Let my assistant install updates**: off, and it can still check, but not install.

The assistant learns the rules from the `AGENTS.md` in its folder (new folders get it from **Create one for me**) and from Zeus itself when it connects. The template says:
- Change Zeus's character, theme, size or appearance only when I ask, or to use something you just made at my request.
- Prefer moving Zeus near the active window over exact coordinates, and don't move it while I'm typing to it.
- Never hide Zeus indefinitely.
- Install an update only when I ask or have told you to keep Zeus current.
- Expect an Undo line for every change, and never undo one yourself.

The 0.1.8 template also covers ending a turn (one short message when it did what you asked, nothing for routine upkeep), questions you skip (never asked again) and clickable links. A folder made before 0.1.8 doesn't have those sections; copy them from a new one if you like. Zeus enforces the control rules either way.

### Learn from me

**Settings → Privacy → Learn from me** is off until you turn it on. The first time, Zeus explains what it records:

> Zeus records how you use this Mac so your assistant can pick better moments to help. Each morning it sends a short summary of the day before.
>
> **Zeus records:** which app is in front, and when it changes · apps opening and quitting · locking, sleeping and waking your Mac · times with no input for 5 minutes or more · how many displays are connected.
>
> **Zeus never records:** what you type, copy or paste · window titles, web addresses and file names · screenshots, audio or your location.
>
> Apps on your private list count only as private time, with no name.
>
> Summaries go to your assistant, which sends them to its model provider like any message. Raw activity never leaves this Mac.

Choose **Turn On** or **Not Now**. Then, in the same pane:
- **What Zeus has recorded** lists today's events in plain words, newest first.
- **Notes to your assistant:** besides the morning summary, up to four notes a day: first activity of the day, back from a break of 2 hours or more, a later start than usual, and the day winding down. Untick any you don't want.
- **Private apps** starts with common password managers, Keychain Access, Passwords and System Settings. **Add App…** adds another.
- **Keep activity for** 7, 14, 30, 60 or 90 days (30 by default). Summaries are kept for a year.
- **Pause for Today** stops recording until midnight. **Delete Everything…** removes all activity and summaries, after asking.

Each summary or note also adds a quiet line to the conversation, such as *Sent your daily summary · View*. **View** shows the exact text your assistant got.

The template tells your assistant to use learnings for timing and tone only: when to speak and what to have ready. It never comments on your habits, never quotes the numbers back unless you ask, and never puts them in messages to other people.

## 3. Pick a character

**Settings → Character**:
- Pick one of 12 characters: Zeus, Wisp, Jack, Gizmo, Sprout, Merlo, Midnight, Bones, Gloop, Nyx, Hoot or Spore.
- **Size** (Small, Medium or Large) sets how big it draws.
- **Fade Zeus when idle** makes the character see-through (10–90 %) after a while without use (5 seconds to 10 minutes). It comes back when you point at it, click it, or something new arrives. It still takes clicks while faded.
- **Reset Avatar Position** brings it back if it's ever off screen.

Your assistant can also change the costume when you ask it to.

### Make your own character

A character is one JSON file: a palette, a few layers of pixel rows, and an animation for each state. No code.

1. In **Settings → Character**, press **Open Example**. Zeus writes `Example Character.json` into your Characters folder and opens it. Every part has a `"_help"` note explaining it.
2. Save a copy in the same folder under a new name and change its `"id"` to your own (letters, digits, `-` and `_`). Zeus skips any file whose id starts with `_`, which is why the example itself never shows up.
3. Edit and save. Zeus reloads the folder as soon as a file changes, so your character redraws on the desktop while you work. If a file has a mistake, Settings → Character says what and where, for example *Layer "body": row 5 is 15 pixels wide; every row must be 16.*

Got a character file from someone else? Press **Import Character…** and choose it. Zeus checks it first, copies it into the Characters folder and switches to it. A character with the same `id` as a built-in one replaces it, and Zeus asks before it does. **Open Characters Folder** shows the folder (`~/Library/Application Support/Zeus/Characters/`) in Finder; delete a file there to remove that character.

The full format is in [design/SPRITE_FORMAT.md](design/SPRITE_FORMAT.md). Building from source? Check a folder of files with:

```sh
swift run --package-path Packages/ZeusKit zeus-sprites validate ~/Library/Application\ Support/Zeus/Characters
```

### Themes

**Settings → Appearance** picks the colors of the conversation panel, Zeus's speech bubble and Settings. The character keeps its own colors.
- **Classic** (the default) follows your Mac: Midnight in dark mode, Parchment in light mode.
- Also built in: Midnight, Parchment, Olympus, Phosphor, Pocket and Sorbet.
- With **Increase Contrast** on in macOS, Zeus switches to high-contrast colors whatever the theme.

**Make your own theme:** press **Open Example**, save a copy in the Themes folder with a new `"id"`, and edit its colors. Zeus picks up changes as soon as you save. **Import Theme…** adds a theme file someone sent you, and **Open Themes Folder** shows `~/Library/Application Support/Zeus/Themes/`. A theme with hard-to-read colors still works but shows **Low contrast**. The format is in [design/THEME_FORMAT.md](design/THEME_FORMAT.md).

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
   tmux new-session -s codex codex --no-daemon -c 'mcp_servers.zeus.env_vars=["TMUX","TMUX_PANE"]'
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

### The status strip

A line between the conversation and the message field says why Zeus looks the way it does, and takes you there in one click (or ⌘J):

| Zeus shows | The strip says | Click it to |
|---|---|---|
| "?" | **? Waiting for your answer · Go to question**, or **? 2 questions · Go to oldest** | jump to the question, ready to answer; again for the next one |
| "!" | **! 3 unread · Show** | jump to the first message you haven't seen |
| "!" (Zeus runs it) | **! Waiting for you in Terminal · Open** | open Terminal |
| working | what it's doing, e.g. *Claude is working on tests* | jump to the bottom |
| red "!" | **Message not delivered · Show** | jump to the message |
| asleep | **Quiet until 8:00** | |

**Skip** (⌘⇧J) closes the oldest open question without an answer and tells your assistant you skipped it, so it moves on instead of asking again. The agent's own Terminal prompts can't be skipped.

On the right: **Open in Terminal** (when there's a terminal to open), **Start New Conversation…** (Zeus runs it), **Clear Conversation…** and **Assistant Settings…**. Clicking Zeus while it shows "?" or "!" opens the conversation at that question or message.

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
| I want a sound when Zeus pops up (or I don't) | Settings → General → **Sounds**: turn on **Play a sound when Zeus pops up** and pick the Zeus chime or a macOS sound. It plays at your alert volume (System Settings → Sound) and stays quiet while Zeus is hidden, during quiet hours and while the conversation is open. |
| My own character doesn't show up | Run `zeus-sprites validate` on your folder (§3). Files with errors are skipped. |
| The assistant posts too often or too rarely | Edit "When to reach out" in your assistant folder's `AGENTS.md`. It's yours to tune. |

## Updates

Release builds check for updates once a day. Choose **Check for Updates…** in the
Zeus menu to check now. A scheduled update appears quietly as **Update Available…**;
select it to see the release notes and install. Settings → General has
**Automatically check for updates**, with the current version and build below it.
Debug builds never check for updates.
