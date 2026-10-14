# Zeus

A small animated pixel character on your Mac's desktop that is the face of your AI assistant.

Your assistant (Claude Code, Codex or OpenCode) does the thinking. Zeus is how it talks to you: it shows messages and progress, asks questions with one-click answers, hands you finished work (files, folders, links), and sends your replies back into the running session. Zeus can run the assistant for you in a tmux session, or connect to one you started yourself.

## Install

Download the latest `Zeus-<version>.dmg` from [Releases](../../releases), open it and drag Zeus into Applications. Zeus lives in the menu bar and checks for updates itself. Setup takes a minute: see [docs/SETUP.md](docs/SETUP.md).

Requires macOS 26 or later, [tmux](https://github.com/tmux/tmux) and at least one of Claude Code, Codex or OpenCode.

## Build from source

```sh
brew install xcodegen tmux
scripts/build.sh    # builds ZeusKit and build/DerivedData/Build/Products/Debug/Zeus.app
scripts/test.sh     # package and app tests
open build/DerivedData/Build/Products/Debug/Zeus.app
```

Debug builds are ad-hoc signed and never check for updates. Signed, notarized releases come from `scripts/release.sh` (see [docs/RELEASE.md](docs/RELEASE.md)).

## How it works

- `zeus-mcp` is an MCP server the assistant connects to. Its tools (`zeus_say`, `zeus_ask`, `zeus_present`, `zeus_set_status`, …) drive the character and the conversation panel.
- Replies go back into the assistant's terminal session through tmux, and each one is acknowledged, so a message is never lost or delivered twice.
- Everything is local. Zeus never calls model APIs, never edits your agent's settings and never accepts prompts on your behalf.

The full design is in [PRODUCT_PLAN.md](PRODUCT_PLAN.md) and [docs/CONTRACT.md](docs/CONTRACT.md).

## Contributing

Read [AGENTS.md](AGENTS.md) (also loaded by `CLAUDE.md`) for the standards every change follows. It works as instructions for coding agents too.
