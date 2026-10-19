# Zeus — Contributor Guide

Instructions for anyone changing Zeus, human or coding agent. `CLAUDE.md` includes this file.

Zeus is a macOS menu-bar app: an animated pixel character that is the face of your AI assistant (Claude Code, Codex or OpenCode). The assistant drives it through an MCP server (`zeus-mcp`, embedded in the app). Zeus can also run the assistant itself in a tmux session.

## Read first
- `README.md`: what Zeus is and how to build it.
- `docs/CONTRACT.md`: the interfaces between the app, the bridge, the runtime and the design system. Keep it in sync with the code; a change to an interface is a change to this file in the same commit.
- `docs/design/*.md`: the specs for each surface (conversation, cards, managed session, rendering).
- `docs/SETUP.md` and `docs/RELEASE.md`: user setup and the release pipeline.

## Layout
| Path | What |
|---|---|
| `Zeus/` | The macOS app target (SwiftUI + AppKit). `Zeus/App/Tests` is the app test target. |
| `Zeus/Bridge`, `Zeus/Agents` | The MCP bridge server and the agent runtime (delivery into tmux panes, managed sessions). |
| `Packages/ZeusKit` | Local Swift package: `ZeusProtocol`, `ZeusMCPCore`, `ZeusLink`, `ZeusSprites`, `ZeusDesign`, the `zeus-mcp` bridge and the `zeus-sprites` CLI. |
| `Zeus/Resources/AssistantTemplate/` | The `AGENTS.md`/`CLAUDE.md` Zeus copies into a new assistant folder ("Create one for me"). |
| `TestFixtures/` | Recorded terminal screens and frames the runtime tests parse. |
| `scripts/` | `build.sh`, `test.sh`, `e2e.sh`, `release.sh`, the DMG builder and performance tools. |

## Build & test (definition of done)
- `scripts/build.sh` must succeed with **no new warnings**.
- `scripts/test.sh` must pass (ZeusKit package tests, then the app tests).
- Add tests for logic you write, with Swift Testing (`import Testing`, `@Test`, `#expect`).
- Build output goes to `build/` (git-ignored). The Xcode project is generated from `project.yml` by XcodeGen; don't commit `Zeus.xcodeproj`.
- Requirements: macOS 26, Xcode 26, XcodeGen (`brew install xcodegen`). Runtime features need tmux.

## Standards
- macOS 26+, Swift 6 language mode with complete strict concurrency, SwiftUI + AppKit, Network.framework, Swift Testing.
- **No third-party dependencies**, except Sparkle (app updates) and the bundled OFL pixel font.
- `Packages/ZeusKit` stays iOS-compatible: no AppKit there.
- Match the surrounding code style. Document public API with `///`. No force-unwraps on external input.
- UI copy is plain, short and specific. Visuals come from `ZeusDesign` tokens and components, not one-off colors or fonts.

## Safety rules (these protect users)
- Zeus never edits the user's agent configuration, MCP settings or credentials, and never auto-accepts an agent's prompts.
- Tests and scripts must never touch the user's real tmux server, agent configs, keychain or home folder. Use a private tmux socket (`-S`/`TMUX_TMPDIR`), a scratch folder and a disposable `HOME`. cfprefsd ignores `HOME`, so scratch `UserDefaults` take an absolute-path suite name (`TestDefaults.suite(_:)` in tests); `scripts/test.sh` fails if a run leaves a plist in `~/Library/Preferences`.
- Never commit secrets, signing identities, personal paths or machine names. Release signing values live in the git-ignored `scripts/release.local.env`.

## Pull requests
- Keep changes focused; describe what changed and how you verified it (commands run, and what you checked by hand in the running app).
- For UI changes, include a screenshot or a render from `scripts/design-harness/render.sh`.

Maintainers may keep local process notes in a git-ignored `.team/` folder. If it exists, read it too.
