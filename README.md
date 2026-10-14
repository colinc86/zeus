<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/hero-dark.gif">
    <img src="docs/readme/hero-light.gif" width="880" alt="Zeus, a pixel-art god on a cloud, asks “Your Q3 review is Thursday at 10. Want me to start the slides?” Start them is clicked, he works through a progress bar, then says “First draft ready.”">
  </picture>
</p>

<p align="center">
  Compatible with Claude Code, Codex or OpenCode.
</p>

<p align="center">
  <a href="https://github.com/colinc86/zeus/releases/latest"><b>Download for macOS</b></a>
  &nbsp;·&nbsp; <a href="docs/SETUP.md">Setup guide</a>
  &nbsp;·&nbsp; macOS 26 or later
</p>

## What it does

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/readme/conversation-dark.png">
  <img src="docs/readme/conversation-light.png" align="right" width="330" alt="The conversation panel: a question answered with one click, finished slides with Open and Show in Finder, and the assistant exporting a PDF at 60%.">
</picture>

Your assistant works in a terminal you're not watching. Zeus sits on your desktop and keeps you in the loop.

- **Shows what it's doing.** Zeus thinks, works and cheers along with your assistant, with a progress bar when there is one.
- **Asks, and you answer in one click.** When your assistant needs a decision, a speech bubble pops up next to Zeus. Click an answer, or type one.
- **Hands you finished work.** Files, folders and links, ready to open.
- **Sends your replies back.** Type to Zeus and your message goes straight to your assistant.
- **Tells you what's waiting.** A strip above the message field says why Zeus shows "?" or "!" and takes you there in one click. **Skip** a question you'd rather not answer. Its four buttons open Terminal, start a new conversation, clear the conversation and open Settings.
- **Knows when to be quiet.** Set quiet hours and Zeus won't bother you.

<br clear="right">

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/peek-dark.png">
    <img src="docs/readme/peek-light.png" width="520" alt="A speech bubble next to Zeus asks which venue to book, with three answer buttons.">
  </picture>
</p>

## Zeus can run your assistant for you

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/readme/settings-dark.png">
  <img src="docs/readme/settings-light.png" align="left" width="380" alt="Settings › Assistant with “Zeus runs it” selected: Claude Code is running in the Assistant folder, with the tmux attach command, Open in Terminal, Restart and Stop.">
</picture>

Zeus starts the assistant in its own tmux session, keeps it running, and picks up the same conversation on each launch. Peek in whenever you like with **Open in Terminal**, or copy the `tmux attach` command.

You pick its permission mode. When it asks for permission, you answer right in the chat. Zeus never answers for you.

Already run your assistant yourself? Choose **Connect your own** and Zeus joins the session you started.

<br clear="left">

## Customize your assistant

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/roster-dark.gif">
    <img src="docs/readme/roster-light.gif" width="880" alt="Eight pixel characters (Zeus, Wisp, Gizmo, Jack, Gloop, Merlo, Midnight and Hoot) going idle, thinking, working, alert and happy together.">
  </picture>
</p>

Twelve cute characters to choose from, or build your own (see [Make your own character](docs/SETUP.md#make-your-own-character) and [the sprite format](docs/design/SPRITE_FORMAT.md)).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/readme/themes-dark.png">
    <img src="docs/readme/themes-light.png" width="792" alt="The same conversation in the Olympus and Phosphor themes: “Make me a cat character.”, the line “Added Pixel Cat · Undo”, then “Here's Pixel Cat. Want a different coat color?”">
  </picture>
</p>

Seven themes color the conversation and Zeus's speech bubble: Classic, Midnight, Parchment, Olympus, Phosphor, Pocket and Sorbet (Settings › Appearance). Themes and characters are plain JSON files: press **Open Example** to see how one is made, or **Import Theme…** and **Import Character…** to add one someone sent you.

**Fade Zeus when idle** makes the character see-through until you need it. Drag the conversation panel's edge to make it wider.

## Your assistant can control Zeus

Ask, and your assistant can change anything you could change by clicking: the character or theme (including ones it makes for you), Zeus's size and place on screen, hiding Zeus for a while, and the appearance settings. It never changes its own authority: it can't answer its own prompts, change its permissions, instructions or folder, start or stop itself, clear the conversation or turn on Learn from me.

Every change shows up as one line in the conversation with an **Undo**:

> **You:** Make me a cat character.<br>
> Added Pixel Cat · **Undo**

It can also check for updates and install one when you ask. Two switches in Settings › General turn this off: **Let my assistant control Zeus** and **Let my assistant install updates**.

## Learn from me

Off until you turn it on in Settings › Privacy. Zeus then notes which app is in front, apps opening and quitting, when you lock, sleep or step away, and how many displays you use. It never records what you type, copy or read, window titles, web addresses or file names. Time in apps on your private list (password managers, to start) counts only as private time.

Each morning your assistant gets a short summary of the day before, and up to four short notes a day, such as when you're back from a break, so it can pick better moments to help. Settings › Privacy shows exactly what was recorded today, pauses it for the day and deletes everything.

Summaries go to your assistant, which sends them to its model provider like any message. Raw activity never leaves this Mac.

## How it works

- `zeus-mcp` is an MCP server your assistant connects to. Its tools (`zeus_say`, `zeus_ask`, `zeus_present`, `zeus_set_status`, …) drive the character and the conversation panel.
- Your replies go back to the session that asked: through its Terminal pane in tmux, Claude Code's channel or OpenCode's local server. Each one is acknowledged, so a message is never lost or delivered twice.
- Everything stays on your Mac. Zeus never calls model APIs, never edits your agent's settings and never accepts prompts on your behalf. If you turn on Settings › Privacy › Learn from me, Zeus sends short summaries of when and in what apps you work to your assistant, which passes them to its model provider like any message; the raw activity never leaves your Mac.

The interfaces are documented in [docs/CONTRACT.md](docs/CONTRACT.md).

## Install

1. Download the latest `Zeus-<version>.dmg` from [Releases](https://github.com/colinc86/zeus/releases/latest).
2. Open it and drag Zeus into Applications.
3. Open Zeus. It lives in the menu bar and updates itself.

You need macOS 26 or later, [tmux](https://github.com/tmux/tmux) (`brew install tmux`) and at least one of Claude Code, Codex or OpenCode. Setup takes a minute: see [docs/SETUP.md](docs/SETUP.md).

## Build from source

```sh
brew install xcodegen tmux
scripts/build.sh    # builds ZeusKit and build/DerivedData/Build/Products/Debug/Zeus.app
scripts/test.sh     # package and app tests
open build/DerivedData/Build/Products/Debug/Zeus.app
```

Debug builds are ad-hoc signed and never check for updates. Signed, notarized releases come from `scripts/release.sh` (see [docs/RELEASE.md](docs/RELEASE.md)).

## Contributing

Read [AGENTS.md](AGENTS.md) first. It has the standards every change follows, and it works as instructions for coding agents too (`CLAUDE.md` loads it). For UI changes, include a render from `scripts/design-harness/render.sh`.

## License

MIT. See [LICENSE](LICENSE). The bundled Departure Mono font is under the SIL Open Font License, and its license ships alongside it.
