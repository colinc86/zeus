# SA4 — selected Connect-your-own pane completion

Recorded 2026-10-14. Real Claude Code 2.1.300, Codex 0.162.1 and OpenCode 1.18.31 in PRIVATE 120×40 tmux panes, disposable HOME/XDG/CFFIXED_USER_HOME, localhost deterministic SSE models. Production AppSettings, TmuxPaneDiscovery, runtime, bridge, CardStore, AvatarStatusModel and thread activity mapping. No Computer Use, screen capture, human tmux server, user agent config/credentials or paid model. All spawned CLI process groups, hosts/models, isolated preferences and scratch directories were cleaned up.

## Required live matrix

| Agent | Turn | Prompt returned → no row | Final model response → no row |
|---|---|---|---|
| claude 2.1.300 (Claude Code) | fast | 2.875 s | 2.941 s |
| claude 2.1.300 (Claude Code) | second | 3.009 s | 3.056 s |
| codex codex-cli 0.162.1 | fast | 2.961 s | 3.101 s |
| codex codex-cli 0.162.1 | second | 3.003 s | 3.105 s |
| opencode 1.18.31 | fast | 2.467 s | 2.739 s |
| opencode 1.18.31 | second | 2.545 s | 2.651 s |

All six turns pass the ≤5-second gate. Each user-style launch omits Zeus completion hooks: no Claude `--settings`, no Codex `notify`, no OpenCode plugin. The recorded argv asserts that absence. Claude injects only its scratch MCP definition and tested tool allowances. Codex saves MCP config only in its disposable CODEX_HOME and passes verified namespace env_vars with --no-daemon. OpenCode uses its scratch inline provider/MCP config, starts a native conversation manually, and has external plugins disabled. No development-channel flag or default tmux server is used.

After the bridge connects, the host invokes production TmuxPaneDiscovery in that session's namespace, pins its assistant session and selects the returned pane via **AppSettings.setTmuxTarget** (the model used by Settings' pane picker). The managed controller stays `off` throughout. No mocked routing model, input reader or classifier replaces the real path. The host supplies only a private-socket process boundary and counts *own sampler* capture commands separately from the delivery connector's input-verification captures.

Every delivered envelope is acked by a real native `zeus_ack` call at attempt 1. Native Bash/exec tools run in the scratch folder and the model finishes with ordinary terminal text, never zeus_say/present/set_status. The recorded TUI is positively idle before timing prompt return; 25 ms host presentation samples show sent/thinking → no row and the avatar back to idle. These are model/presentation measurements, not pixel/UI-click renders. Empty card collections prove a Zeus reply/card did not release the row.

The capture count is **zero before delivery**, the own sampling task is absent after completion, and its count stays unchanged across another 3.3 seconds of idle. No continuous idle polling is introduced. Native times, ANSI/cursor metadata, actual calls/results and delivery IDs are preserved; only private paths/CLI locations are scrubbed. `/tmp` and `/private/tmp` identify the same macOS socket; the fixture boundary compares normalized paths, matching production Settings/runtime checks.

## Implementation / evidence rules

- Samples begin immediately after an implicit delivered response exists, then wait 3 seconds between captures. Only the current Connect-your-own assistant, Its Terminal pane method, an explicitly selected %pane and explicit matching socket qualify. A bridge's automatic pane fallback alone does not authorize sampling.
- Before and after capture, verify actual socket, pane/server/session identity, live pane/server process start times, and the registered agent PID/start within the pane's bounded parent ancestry. No @zeus-owner option is added to own sessions. Ambient TMUX/TMUX_PANE are cleared; every command has an explicit -S and is display-message or capture-pane. No input/control/config mutation is available through the reader.
- Runtime generation, bridge session ID, selected destination and per-response token must still match around every suspended operation. Selection changes, disconnects, replacement responses, explicit working status, completed activity and runtime shutdown cancel the old task and invalidate its evidence.
- Reuse the managed classifier and common screen-activity reducer: working can advance sent → thinking and extend only implicit stale time; positive idle after observed work, fresh native completion, or the existing conservative 20-second idle grace can release it. Unknown/errors/permission modals do not end it. An explicit working TTL remains authoritative and does not start own sampling.
- There is no pre-delivery own-pane sample. Therefore Claude's completion parser additionally requires this response's exact delivery envelope in history; an old footer cannot serve as a first-sample baseline. The live composer/footer are excluded. Codex/OpenCode reuse SA2's exact delivery-ID history/completion correlation. Scheduled Claude task footers retain SA1's exclusion.
- Never creates a response, changes delivery acknowledgments, mirrors native prompts, publishes draft alerts/blocked cards or types an answer. An idle own pane with human text can end an already-completed response without treating that text as a managed draft.

## Tests and verification

Recorded SA3/SA2 fixtures plus a fake clock cover all three agents' fast native completion, old completion against a new input, working → idle, native idle with human draft, blocked permission screens, no resurrection, explicit TTL/no sampling, missing selection/socket, wrong namespace, newer response, selection/socket/session changes, disconnect, stop and say during a suspended capture. Reader tests verify read-only commands, no ambient namespace, dead/recycled PID, replaced pane and permission revoked before capture. Managed SA1/SA2 activity regressions also passed.

```sh
scripts/build.sh
python3 -B Zeus/App/Tests/Runtime/SA4LiveProbe.py --record
scripts/test.sh
scripts/check-public.sh
```

The live host is opt-in and excluded from the normal app test executable by SA4_PROBE_HOST. It copies production sources to build/ without modifying their behavior; Settings dependencies compile unchanged. A fake password store guarantees no Keychain lookup. The pending full-gate result is recorded in the hand-back.

## Proposed CONTRACT §10.8 addition (PM-owned)

Extend managed screen completion rules to a Connect-your-own assistant using Its Terminal pane **only when the user explicitly selected that pane and its socket matches the registered session**. Capture read-only every 3 seconds only while that session has implicit sent/thinking activity; stop on completion, selection/mode change, disconnect or runtime shutdown. Validate native pane/server/agent lifetimes around capture, and revalidate session/destination/generation/response token after awaits. Positive idle after working or fresh native completion uses the same activity rules and conservative idle grace; for own Claude without a pre-response sample, require the current delivery envelope rather than accepting any old footer. Explicit working TTLs and all delivery/routing semantics stay unchanged. Own sampling does not mirror prompts, alert on drafts or create blocked cards. Unselected/no-namespace sessions retain hook/stale behavior. No Shared/CONTRACT edit made.
