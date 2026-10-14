# SA3 — native completion without an assistant message

Recorded 2026-10-14. Real installed Claude Code 2.1.299, Codex 0.162.1 and OpenCode 1.18.31; production bridge/runtime, CardStore, AvatarStatusModel and thread activity mapping. Each CLI uses a private 120×40 tmux pane, disposable HOME/XDG/config and a deterministic localhost model. All panes/process groups, hosts, models and scratch profiles were cleaned up. No human tmux/config/credentials, paid API, screen capture or Computer Use.

## Passing completion proof

Connect-your-own mode stays `off` throughout: no managed controller/screen monitor can release activity. Settings' actual `SetupCommands` constructs the launch command, with the branch's embedded bridge and private socket. Claude uses exactly that command's generated hook settings, plus fixture-only MCP injection, model/allowance flags and a second, silent hook that records native stdin. The copied headless runtime logs incoming wire metadata without changing its callback or guards. Normal turns call the real `zeus_ack`; Claude's first turn also executes real Bash; Codex/OpenCode execute their real command tools. None calls `zeus_say`, `zeus_present` or `zeus_set_status`.

Codex's generated `tmux new-session` wrapper is replaced only by the fixture's already-created private pane; its native launch argv retains `--no-daemon`, namespace `env_vars` and generated `notify`. Its scratch allowance permits only the tested Zeus ack tool. OpenCode uses the generated `zeus-mcp --hook-settings` result, a real local file-URL plugin (external plugins enabled only in this empty private profile), and a manually started native conversation before composing. Model endpoints, fixture permissions and private sockets are the only launch adaptations. This verifies the new completion path through tmux; it does not re-prove the existing OpenCode HTTP connector.

The table measures real localhost final-response completion → observed no activity. Hooks can clear before native paint finishes; the recorded native idle frames confirm the turn ended. These are headless presentation measurements, not pixel/VoiceOver measurements. Every native ack is durable at attempt 1; the cards collection remains empty. Timeline shows idle → sent/thinking → idle, in the same bridge session without reconnecting.

| Native CLI | Turn | Completion to activity clear |
|---|---|---|
| claude 2.1.299 (Claude Code) | fast | 0.067 s |
| claude 2.1.299 (Claude Code) | second | 0.066 s |
| codex codex-cli 0.162.1 | fast | 0.035 s |
| codex codex-cli 0.162.1 | second | 0.069 s |
| opencode 1.18.31 | fast | 0.067 s |
| opencode 1.18.31 | second | 0.061 s |

Claude's synthetic HTTP 400 also generates real `StopFailure` and ends activity. `claude-probe.json` contains that native hook, error pane and the passing repeat-turn proof. Codex's documented argv JSON and OpenCode's real `session.idle` plugin callbacks arrive with matching parent lifetimes and native IDs. In OpenCode, the plugin queries the actual session's message parent to select that completed input, retaining its completion timestamp before asynchronous lookup/exec.

## A race found by real Claude

The first implementation's repeat turn retained `thinking`: Stop could execute before the new user frame had been flushed to the transcript. Selecting the latest on-disk user text incorrectly supplied the preceding delivery ID. The hook now restricts correlation to native `prompt_id` → transcript `promptId`; a missing/unflushed match supplies no delivery ID rather than borrowing an old one. Runtime lifetime/time/token guards still apply. The recorded repeat has either its own ID or no ID, and releases only its current implicit response. A bounded transcript read, stale-prompt regression and synchronous-answer result handling cover this.

## Interrupted turns: native gap requiring PM decision

`claude-interruption-probe.json` is deliberately a **failing** live case, retained independently of the passing proof. After a real ack, the fixture holds the next model response, presses Escape, and the real TUI renders **Interrupted · What should Claude do instead?** with an empty composer. The native transcript records `interruptedMessageId` and `[Request interrupted by user]`. No Stop, StopFailure or Notification signal arrives for this interruption within 70 seconds. The runtime remains thinking. All normal/error hooks in that same run do arrive.

[Claude's native hook reference](https://code.claude.com/docs/en/hooks) explicitly excludes user interruption from Stop. We install additive StopFailure, SessionEnd and Notification/idle_prompt hooks too, but the idle notification is not a reliable interruption signal in the installed private CLI. Runtime accepts `.interrupted` and releases it under exactly the same guards (unit-tested); there is no honest immediate Escape producer in the approved stateless hook design. Existing managed screen completion and Connect-your-own five-minute stale fallback remain. Suggested PM choice: accept/document this native limitation, or authorize a separate launch-only transcript observer for native interruption metadata. No persistent observer, terminal polling, saved agent-config edit, or invented successful interruption signal has been added.

## Safety and launch behavior

- Claude `--settings` merges the generated hooks for this process; no permission decision or saved hook is changed. Commands produce no MCP stdout. `--turn-ended` sends one event and waits at most one second for its receipt, then exits; native command hooks also have a 1.5-second timeout.
- Codex's [official notification configuration](https://developers.openai.com/codex/config-advanced/) supports launch `-c notify=[...]` and only documents `agent-turn-complete`. It replaces a custom notifier **for this launch only**. That limitation is stated in SETUP.md; no native config is read or overwritten to synthesize a chain. Existing MCP/environment injection remains.
- OpenCode supports [plugin events](https://opencode.ai/docs/plugins/) and [launch inline configuration](https://opencode.ai/docs/config/). Zeus generates its own content-addressed module in its support directory for copied launches, or the owned managed-launch artifact directory for managed sessions. Native plugin lists merge with saved settings. The copied command's `OPENCODE_CONFIG_CONTENT` must be merged manually if a user already supplies launch-inline config. A `session.error` correlates the latest user input instead of a preceding completed assistant.
- Tools/results/acks and routing are unchanged. The hook never registers a bridge, selects an assistant, changes a delivery's ack, retries a message, sets a pose, or revives a response. It never overrides explicit working TTL.

## Contract proposal for PM (§3 and §10.8)

No CONTRACT/Shared edit made. Proposed wire table entries:

- native helper → app, first/only frame: `turnEnded {wireVersion:1, agent, pid, ppid, cwd, ancestors:[{pid,startTime}], firedAt, reason, tmuxPane?, nativeSessionID?, deliveryID?}`. `startTime` is µs Unix process lifetime; `firedAt` is Unix seconds, captured before notifier input/file/socket work (OpenCode can supply the native completion time).
- app → helper: `turnEndedReceipt {}`. It acknowledges callback completion, not a model/delivery acknowledgment. No hello, bridge registration or session replacement occurs; receipt/failure is silent and best-effort.
- `reason` is `completed|interrupted|error|sessionEnded|idle`. Match agent + exactly one registered parent lifetime in the bounded ancestry, never cwd/pane alone; when an exact OpenCode destination is known its native ID must agree.
- End only implicit sent/thinking whose input began by `firedAt` and whose optional delivery ID matches. Capture the per-response token, runtime generation and activity epoch before suspension; a changed response, disconnect/restart or explicit working status invalidates that lease. Tombstone only a correlated already-started input/result so a fast completion cannot be resurrected by a late connector/answer receipt, while newer in-flight input retains its own receipt.
- Explicit working status/deadline stays untouched for every end reason. Native producers are launch-specific; launches without hooks retain existing screen/stale behavior. The inability to observe external Escape immediately requires the decision above.

## Verification / reproduction

```sh
scripts/build.sh
python3 -B Zeus/App/Tests/Runtime/SA3LiveProbe.py --record
# Expected failing optional probe, preserving the native interruption gap:
python3 -B Zeus/App/Tests/Runtime/SA3LiveProbe.py --agent claude --interrupt-check --record
scripts/test.sh
scripts/check-public.sh
```

Full gate: 751 app tests, 236 package tests; build succeeds with no new warnings (existing ManagedTerminal unused binding / destination warning only). Focused tests cover flat wire round-trip, one-shot/non-evicting transport, bounded stalled receipt, launch fresh/resume and copied-command quoting, PID reuse/same-folder agents, wrong native conversation, all end reasons/TTL, newer-response time/token guards, early connector/answer receipt, and newer in-flight receipt preservation. Fixtures scrub only private paths and executable locations; ANSI/cursor, native opaque IDs, times and calls/results are preserved. Repeated unrelated native telemetry is omitted.
