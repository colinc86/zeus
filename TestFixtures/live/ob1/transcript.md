# OB1 — first run, live

2026-10-14. Real Claude Code 2.1.300, production ShellController, Settings/Conversation views and models, managed controller, runtime, CardStore and AvatarStatusModel. The native fixture app has its own disposable HOME, preferences, assistant folder, localhost SSE model and explicit private tmux socket. No human agent configuration, credentials or default tmux server is read. Input uses the fixture window's NSTextView and in-process accessibility actions, with no global events or screen capture. The fixture disables global shortcut registration.

Reproduce after `scripts/build.sh` with `python3 -B Zeus/App/Tests/OB1LiveProbe.py --record`. The host is compiled from the worktree's production sources; its only injection boundaries are private storage, executable discovery, tmux namespace, credential store and localhost model. The managed-off mode selection uses the production ManagedAssistantModel; its real confirmation sheet is answered by native AX Stop. Only Claude is advertised as installed in the fixture's injected executable discovery. The setup assistant's own onboarding is pre-completed in its synthetic profile; this is a new **Zeus** install, not a test of signing up with Anthropic. The fixture operator accepts only its new scratch-folder trust prompt and synthetic localhost API key in the private pane. Zeus does not auto-accept either.

## Before / after

- `baseline.json`: fresh managed setup consumed the welcome marker but produced no card. Native panel empty, avatar idle, menu “Claude Code hasn't started”, strip “Idle”. Restored D19's welcome while persisting the managed choice before the welcome marker. The welcome is read and quiet: no peek, sound or talking transient. The marker is not consumed if card persistence fails.
- `before-off-fix.json`: the complete exploratory walk reached confirmed Stop, but menu said “Ready to talk” and strip “Idle”. Both now say “Your assistant is off” only for a known stopped/never-started managed assistant, with no connected or retained session. Questions, unread, activity, delivery problems and quiet hours keep their precedence.
- An intermediate walk left the second question unread after composing again following an option click. A deterministic native AX regression reproduced the related accepted-send gap: from unpinned history, the draft was sent but the new bubble's bottom was at 1925 pt while the viewport ended at 602 pt. The composer callback never requested latest after an accepted send. It now does so after restoring composer focus; a failed send keeps both its draft and history position. This proves the send-after-unpin defect, without claiming that it establishes every timing detail of the earlier live observation.

## Full native walk

Elapsed times from `probe.json`, in seconds. State samples are separate from the monotonic parent milestones; `host_pid` disambiguates the sampler clock reset on relaunch.

| Step | Expected | Observed | Time |
|---|---|---|---:|
| Fresh launch | Only D19 welcome; idle; assistant off | Exactly `c_welcome1`, seen; idle; menu and strip “Your assistant is off” | 1.083 |
| Welcome → Settings → Assistant | “Zeus runs it”; create a folder; field refreshes | Native “Settings, Assistant” AX action, “Create one for me”; folder filled; both AGENTS.md and CLAUDE.md byte-identical to bundled templates | 2.621 |
| Start | Starting, then running | Native Start AX action; menu “Starting Claude Code…”; then “Claude Code is ready”, idle | 2.737–19.323 |
| Composer | Delivered/acked, thinking, reply, idle | Real NSTextView input + native AX Send; acked receipt; thinking; real zeus_say card; once-only reveal observed; idle | 21.393–27.633 |
| Link | Accessible clickable link | Two backing AXLink elements with label “Read the fixture guide”; production OpenURL path retained | 27.633 |
| Options | Question → ? / waiting strip → click → idle | Avatar waiting; strip “Waiting for your answer”; native “OB1 Yes” AX press; answer reaches model; idle | 32.442–36.181 |
| Skip | Question → Skip → model receives skipped → idle | Native strip Skip AX action; persisted skipped response and actual MCP tool_result `status: skipped`; idle without another zeus_say | 41.365–45.32 |
| Quit/relaunch | Agent remains; same owned conversation | Pane remained alive while Zeus quit; pane ID, PID, process start, native conversation ID and nonce unchanged; reconnected idle | 58.222 |
| Managed off → Stop | Confirmation; only owned agent stopped; honest off | “Stop the Zeus-run agent?” AX sheet; native Stop; no pane, managed disabled, zero sessions; menu and strip off | 59.686 |

The installed Claude's production launch does not request development channels, so the development-channels dialog did **not** appear. Its mirroring/answering is not claimed as exercised by this run. The harness handles that specific mirror if it appears on a supported launch. Link verification checks the actual AX link and production URL handler, without opening an external browser. Typewriter verification samples the production revealer's active state and subsequent persisted revealed state.

`welcome.png` is a native NSHostingView cache-display render of the actual fresh production conversation window, not a screen capture. It shows the welcome, setup buttons, off strip and focused composer. The optional Start/Set Up strip link from design review is deferred; the welcome and menu already supply those actions.

## Regression / gates

- `9578178`: five OB1 regressions cover the fresh welcome/mode on relaunch, failed card persistence, quiet ShellController startup, off-state eligibility and question precedence. Updated the older assertions that intentionally expected an empty first run.
- `d4c5156`: native AX Send from earlier history, both accepted and failed; current Q3 scroll regressions and outgoing-message integrity. Before-fix failure excerpt: `scroll-before.txt`. After fix: all 18 tests in the two focused suites pass.
- Platform read-only cross-review of `9578178` and `d4c5156`: no lifecycle/persistence or scroll blockers. Designer approved the copy/shape; no ZeusDesign changes.
- Final `scripts/build.sh`: passed, no new warnings. The first compile emitted existing Sendable conversion warnings in untouched AppearanceSettingsView and CharacterSettingsView; the scripts also retain the existing ambiguous architecture destination warning.
- Post-scroll-fix native walk: all seven steps pass, including reply-specific typewriter activity and real model skipped result. The idle observations require the native prompt plus a stable 400 ms idle sample; a transient receipt handoff is not counted as completion.
- Final `scripts/test.sh`: passed — 787 app tests in 162 suites, 241 package tests, 16 offline release/appcast checks. Standard opt-in active-keyboard checks remain gated by their existing environment flags; this OB1 live walk used its own unlocked native fixture window. No production/runtime or ZeusDesign edits outside appdev ownership.
