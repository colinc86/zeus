# CY1: Connect your own

The production conversation composer, AppSettings session-picker binding, bridge server and default connector order were exercised against installed Claude Code, Codex and OpenCode. Each CLI ran as a separately configured agent, with managed mode **off** and no managed launch, ownership or adoption. All profiles, project files and tmux processes were isolated under a disposable `/private/tmp/zcy1_<uuid>` root, with a private `-S` socket. Model requests went only to a localhost fixture using a synthetic key; no user credentials or configuration were read or changed.

## Live results

| CLI | Selected route | Composer reaches native CLI/model | Real `zeus_say` reaches thread |
| --- | --- | --- | --- |
| Claude Code 2.1.299 | Its Terminal pane | Passed | Passed |
| Codex 0.162.1 | Its Terminal pane | Passed | Passed |
| OpenCode 1.18.31 | OpenCode HTTP, explicitly chosen native conversation | Passed | Passed |

The test selected the exact connected session key through the picker's persisted binding. Claude/Codex then selected their pane in that socket through the same `AgentSettingsView.selectPane` action as Settings. OpenCode used the real `GET /session` listing and `OpenCodeSessionPicker.select`: exactly one fixture conversation was listed and explicitly selected, never an automatic newest-session choice. The composer submitted `CY1_COMPOSE_PROBE: Please reply with zeus_say.` via `ConversationModel.send`. The localhost request log contained that input; the CLI executed the fixture's `zeus_say` tool request through the bundled bridge, and the resulting card had the selected session key and appeared in `ConversationModel.thread`. A transport receipt alone was not counted as a pass.

The per-agent JSON records the installed version and these checks. The ANSI files are native terminal captures from only the private socket. The `*-registration.json` and `*-launch.json` files record the actual fixture commands. `/FIXTURE`, `/CLI/<agent>` and `/BUNDLE/Zeus.app` replace local paths. The disposable Codex config preapproves only `zeus_say`; Claude's launch allows only that Zeus tool, and OpenCode's disposable permission map allows Zeus tools. No other tool/trust/permission choice is answered automatically. The fixture-human accepts only Claude's own scratch-folder trust, synthetic-key setup and requested development-channel consent when those exact screens are present.

## Issues found and fixed

- **Codex MCP environment filtering:** the original Settings command, and `--no-daemon` alone, connected a bridge without pane/socket metadata. A composer message could not be routed to its Terminal pane. Both appdev and platform independently verified the launch-only whitelist below. It forwards the current tmux namespace without storing an old pane in the user's MCP configuration. Settings now shows this exact command, with a regression test; the live fixture also checks that its saved Codex configuration contains no `TMUX` values.

  ```sh
  tmux new-session -s codex codex --no-daemon -c 'mcp_servers.zeus.env_vars=["TMUX","TMUX_PANE"]'
  ```

- **Claude explicit route ignored:** before platform's approved `d06f866` fix, the production connector order chose a channel even after selecting Its Terminal pane. The composer showed a transport receipt, but the CLI/model never received the message and no reply reached the thread. `ChannelDeliveryConnector.canDeliver` now respects the selected/effective channel method. The same fixture passes without reordering or replacing the connectors; the owner's real-bridge regression covers channel, tmux, OpenCode and polling, including zero channel pushes for tmux. Managed readiness and fallback remain on their existing effective-route override. CONTRACT §5.2's channel-first wording needs PM alignment with that explicit/effective selection rule.

The synthetic API-key Claude reports `Channels are not currently available` and ignores the development-channel flag. Its selectable Terminal route is fully verified; a signed-in subscription account's actual channel delivery was not exercised. The original standalone launch also revealed a fixture argument error: Claude's variadic `--allowedTools` consumed the initial probe. Placing `--permission-mode manual` before the prompt corrects the fixture, without a production change.

## Reproduce

From the appdev worktree root, after `scripts/build.sh`:

```sh
xcodegen generate --quiet
TEST_RUNNER_ZEUS_CY1_LIVE=1 TEST_RUNNER_ZEUS_CY1_RECORD_FIXTURES=1 \
TEST_RUNNER_ZEUS_CY1_RENDER=1 \
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/ConnectOwnLiveTests \
  -only-testing:ZeusTests/ConnectOwnModeTests \
  -only-testing:ZeusTests/ConnectOwnRoutingTests \
  -only-testing:ZeusTests/LiveManagedSettingsTests test
```

Omit the record/render switches to verify without rewriting evidence. Ordinary `scripts/test.sh` runs the deterministic model, native confirmation and routing tests; the opt-in live cases stay disabled. The helper kills only its private tmux server and stops its localhost model. An exploratory launch of default Codex created a daemon under its disposable HOME; that specific verified fixture executable was stopped afterward. Final launches use `--no-daemon`.

## PM visual checklist

The PNGs are offscreen, in-process native renders with isolated preferences and a fake password store, not screen captures. The native test sends Escape only through its own window's `performKeyEquivalent` and checks the resulting mode/status and accessibility labels.

- While Zeus runs an agent, select Connect your own. The inline prompt reads **Stop the Zeus-run agent?**, with **Stop** and **Keep Running**. Keep Running receives focus; Escape chooses it.
- Stop waits for the owned pane's teardown, then switches modes. A stop failure leaves managed routing enabled and shows the failure. Existing teardown regressions remain green.
- Keep Running switches immediately, leaves the process alive, and shows **Your Zeus-run agent is still running in tmux (tmux attach -t zeus)**. Collisions/custom sockets show their actual attach command. The notice survives reopening Zeus and disappears when that process exits; a reused PID cannot keep it alive.
- Select a different connected session. New composer messages go to that explicit choice, not the retained managed lease.
- Switch back to Zeus runs it: the retained notice hides. Agent/folder edits retain the existing Switch Now/Later confirmation; Later is focused and Escape leaves the current conversation running.
