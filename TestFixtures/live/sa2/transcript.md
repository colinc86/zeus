# SA2 — managed Codex and OpenCode state accuracy

Recorded 2026-10-14 with codex-cli 0.162.1, 1.18.31.
Real installed CLIs, production managed launch/controller/runtime, real bundled zeus-mcp, CardStore, AvatarStatusModel and thread activity mapping. Private 120×40 tmux panes, disposable HOME/XDG/config, localhost deterministic SSE models; no human server, config or credentials.

Codex uses Ask when needed (`workspace-write/on-request`); OpenCode uses the explicitly selected Allow all policy for the scratch printf tool. Production Zeus-tool approval rules are unchanged. No permission dialog is answered by this probe.

## Measured state transitions

Each agent has its own parent monotonic clock. Prompt return requires the causal final model text, the CLI's native completed-turn summary below it, and no live interrupt control; it is not inferred from the runtime classifier. The host's real 3-second monitor is never manually refreshed. End deltas use the same parent clock; raw host timeline timestamps have their own startup origin. Measurements include sampling and IPC latency.

| Agent | Trigger | Native prompt t | Activity released t | Δ after prompt | ≤5 s |
|---|---|---:|---:|---:|---|
| codex | SA2_SAY | 13.801 | 13.801 | 0.000 s | pass |
| codex | SA2_SHELL | 16.130 | 18.975 | 2.845 s | pass |
| codex | SA2_FAST | 19.450 | 21.965 | 2.514 s | pass |
| codex | SA2_BUSY | 28.343 | 30.979 | 2.637 s | pass |
| codex | SA2_FOLLOWUP | 31.284 | 31.285 | 0.000 s | pass |
| codex | SA2_DRAFT | 34.131 | 37.032 | 2.901 s | pass |
| opencode | SA2_SAY | 13.333 | 13.333 | 0.000 s | pass |
| opencode | SA2_SHELL | 15.808 | 19.244 | 3.437 s | pass |
| opencode | SA2_FAST | 20.129 | 21.692 | 1.563 s | pass |
| opencode | SA2_BUSY | 28.066 | 30.746 | 2.680 s | pass |
| opencode | SA2_FOLLOWUP | 31.296 | 31.297 | 0.000 s | pass |
| opencode | SA2_DRAFT | 33.846 | 36.888 | 3.042 s | pass |

SAY and FOLLOWUP require an actual zeus_say card in the production store. SHELL/FAST/BUSY/DRAFT run a real native shell tool (`printf SA2_SHELL_DONE`) and end with terminal-only output: no zeus_say, zeus_set_status or other clear signal. Every message is really acked at attempt 1. SHELL waits for an observed working sample; FAST completes without a deliberate hold. BUSY queues a second message while the first response is held, verifies attempts 0/no native model arrival and retains the original thinking row, then releases the original delivery's activity before finishing FOLLOWUP. DRAFT adds deliberately unsent text after positive native completion and verifies idle, draft preservation and no activity.

The SAY card's earned 2.5-second talking transient can briefly outrank the next thinking avatar; the thread row follows assistantActivity. BUSY's released timestamp is for its original delivery, not a forced empty UI while the queued followup is producing a response. The final followup and all no-say cases end idle with no activity row.

## Baseline and fix

- codex: the fast shell turn missed the 3-second working samples and retained thinking for 20.673 s after native idle; fixed release 2.514 s.
- opencode: the fast shell turn missed the 3-second working samples and retained thinking for 20.588 s after native idle; fixed release 1.563 s.

The recorded working/idle/draft classifiers already pass both agents. The fix recognizes Codex's native `Worked for … • time` summary and OpenCode's native `▣ … · model · duration` summary only in history above a bounded composer. The summary must follow the latest Zeus envelope, and its delivery ID must equal the existing activity record, with a fresh positive idle sample. An old footer, new input echo, malformed envelope, composer/footer text, or unrelated delivery cannot release a newer response. It never creates activity and does not end explicit statuses. SA1's separate generic TTL-preservation fix must be retained when merging the Activity file; SA2 does not alter that working-screen branch or add a competing ActivityRecord property.

## State / trigger transcript

Milestones below are parent-clock queries; the scrubbed probe JSON also retains the 50-ms changed-state host timeline, all ownership-checked ANSI/cursor captures and actual native tool results.

| Agent | t | Trigger | Managed state | Activity | Avatar | Draft |
|---|---:|---|---|---|---|---|
| codex | 13.207 | managed ready | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| codex | 13.518 | user message: SA2_SAY | running(ManagedSessionStatus.Activity.idle) | sent | thinking | none |
| codex | 13.801 | native prompt returned: SA2_SAY | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| codex | 13.801 | activity ended: SA2_SAY | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| codex | 14.071 | user message: SA2_SHELL | running(ManagedSessionStatus.Activity.idle) | sent | talking | none |
| codex | 15.986 | working sampled: SA2_SHELL | running(ManagedSessionStatus.Activity.working) | thinking | talking | none |
| codex | 16.130 | native prompt returned: SA2_SHELL | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| codex | 18.975 | activity ended: SA2_SHELL | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| codex | 19.208 | user message: SA2_FAST | running(ManagedSessionStatus.Activity.idle) | sent | thinking | none |
| codex | 19.450 | native prompt returned: SA2_FAST | running(ManagedSessionStatus.Activity.idle) | thinking | thinking | none |
| codex | 21.965 | activity ended: SA2_FAST | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| codex | 22.205 | user message: SA2_BUSY | running(ManagedSessionStatus.Activity.idle) | sent | thinking | none |
| codex | 25.012 | working sampled: SA2_BUSY | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| codex | 28.217 | queued mid-turn input retains thinking | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| codex | 28.343 | native prompt returned: SA2_BUSY | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| codex | 30.979 | original busy activity released | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| codex | 31.284 | native prompt returned: SA2_FOLLOWUP | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| codex | 31.285 | activity ended: SA2_FOLLOWUP | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| codex | 31.510 | user message: SA2_DRAFT | running(ManagedSessionStatus.Activity.idle) | sent | talking | none |
| codex | 34.005 | working sampled: SA2_DRAFT | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| codex | 34.131 | native prompt returned: SA2_DRAFT | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| codex | 37.032 | activity ended: SA2_DRAFT | running(ManagedSessionStatus.Activity.idle) | none | idle | SA2 deliberately unsent draft. |
| codex | 37.158 | idle with human draft; no activity | running(ManagedSessionStatus.Activity.idle) | none | idle | SA2 deliberately unsent draft. |
| opencode | 12.772 | managed ready | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| opencode | 13.033 | user message: SA2_SAY | running(ManagedSessionStatus.Activity.idle) | sent | thinking | none |
| opencode | 13.333 | native prompt returned: SA2_SAY | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| opencode | 13.333 | activity ended: SA2_SAY | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| opencode | 13.609 | user message: SA2_SHELL | running(ManagedSessionStatus.Activity.idle) | sent | talking | none |
| opencode | 15.672 | working sampled: SA2_SHELL | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 15.808 | native prompt returned: SA2_SHELL | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 19.244 | activity ended: SA2_SHELL | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| opencode | 19.789 | user message: SA2_FAST | running(ManagedSessionStatus.Activity.idle) | sent | thinking | none |
| opencode | 20.129 | native prompt returned: SA2_FAST | running(ManagedSessionStatus.Activity.idle) | thinking | thinking | none |
| opencode | 21.692 | activity ended: SA2_FAST | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| opencode | 21.943 | user message: SA2_BUSY | running(ManagedSessionStatus.Activity.idle) | sent | thinking | none |
| opencode | 24.713 | working sampled: SA2_BUSY | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 27.925 | queued mid-turn input retains thinking | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 28.066 | native prompt returned: SA2_BUSY | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 30.746 | original busy activity released | running(ManagedSessionStatus.Activity.idle) | none | idle | none |
| opencode | 31.296 | native prompt returned: SA2_FOLLOWUP | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| opencode | 31.297 | activity ended: SA2_FOLLOWUP | running(ManagedSessionStatus.Activity.idle) | none | talking | none |
| opencode | 31.560 | user message: SA2_DRAFT | running(ManagedSessionStatus.Activity.idle) | sent | talking | none |
| opencode | 33.714 | working sampled: SA2_DRAFT | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 33.846 | native prompt returned: SA2_DRAFT | running(ManagedSessionStatus.Activity.working) | thinking | thinking | none |
| opencode | 36.888 | activity ended: SA2_DRAFT | running(ManagedSessionStatus.Activity.idle) | none | idle | SA2 deliberately unsent draft. |
| opencode | 37.056 | idle with human draft; no activity | running(ManagedSessionStatus.Activity.idle) | none | idle | SA2 deliberately unsent draft. |

## Boundaries and reproduction

These are headless production-path measurements, not pixel renders or UI clicks. Model output is deterministic; native tools, MCP subprocesses, delivery receipts, clocks and TUI rendering are real. Only private paths/executable locations are scrubbed; ANSI, wrapping, elapsed times, opaque IDs and cursor metadata are preserved. `*-before.json` is the full valid pre-fix matrix (FAST is its expected failing gate). `*-probe.json` is the fixed matrix. Early harness-development runs are not included.

No dependable new completion is asserted if a long output scrolls its Zeus envelope offscreen, a narrow pane wraps that header before its closing bracket, or an unrecognized native version omits the summary. Those cases retain the observed-working → idle rule and conservative 20-second grace. The TUI *does* provide usable working/idle evidence in the installed versions; no speculative notification or timeout replacement is added. Connect-your-own sessions are outside this managed-session task.

Fake-clock tests replay recorded screens for both agents: fast completion without a working sample, old delivery, echo without completion, active work, queued input, idle with draft, no resurrection, composer/footer exclusion, malformed envelope and explicit-status preservation. Shared/CONTRACT/app-owned production files are unchanged.

```sh
scripts/build.sh
python3 -B Zeus/App/Tests/Runtime/SA2LiveProbe.py --record
scripts/test.sh
scripts/check-public.sh
```

The live probe is opt-in; normal test.sh uses the recorded fixtures. All spawned host/model/pane processes and disposable directories are cleaned up.
