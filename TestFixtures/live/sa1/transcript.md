# SA1 — state accuracy transcript

Recorded 2026-10-14; 2.1.299 (Claude Code).
Real Claude, production managed controller/runtime/CardStore/AvatarStatusModel and activity-row mapping; private tmux socket, disposable HOME, localhost SSE model. No user's server, configs, credentials, global input or screen capture.

The host uses the app's new-card transient hook and real clocks. Option/text/Skip use the production CardStore response path; mirrored permission choices use the runtime's local action handler. This is a headless presentation probe, not a UI click or pixel/render test. Closed-panel speech uses the §7 transient, without the peek/typewriter surface.

## Measured release times

Times are seconds from the localhost fixture's start. Native prompt return is positively classified from a fresh ownership-checked capture, not inferred from delivery or elapsed silence. Runtime/row transitions use the host clock, aligned below with the median adjacent-query offset (approximately 0.334 s). The release deltas themselves use one parent monotonic clock.

For TTL, unread and quiet hours, idle is expected after the earned trigger is released: TTL expiry, opening/reading, or switching quiet hours off. A 30-second explicit status deliberately outlives a finished native turn.

| Scenario | Native prompt t | Idle t | Δ after prompt | Δ after earned release | Gate |
|---|---:|---:|---:|---:|---|
| say | 14.057 | 16.474 | 2.418 s | 2.418 s | pass |
| happy | 16.958 | 19.311 | 2.354 s | 2.354 s | pass |
| work-no-say | 23.930 | 25.515 | 1.584 s | 1.584 s | pass |
| fast-no-say | 25.901 | 28.531 | 2.630 s | 2.630 s | pass |
| ask-option | 31.542 | 31.677 | 0.135 s | 0.135 s | pass |
| ask-text | 34.632 | 37.705 | 3.073 s | 3.073 s | pass |
| ask-skip | 40.717 | 43.616 | 2.899 s | 2.899 s | pass |
| closed-say | 44.141 | 46.583 | 2.441 s | 0.002 s | pass |
| ttl | 51.073 | 76.909 | 25.836 s | 0.031 s | pass |
| auto | 79.525 | 79.665 | 0.140 s | 0.140 s | pass |
| permission-ui | 86.218 | 86.363 | 0.145 s | 0.145 s | pass |
| permission-terminal | 92.057 | 94.833 | 2.776 s | 2.776 s | pass |
| quiet-ask | 98.013 | 98.153 | 0.140 s | 0.279 s | pass |

Both permission cases and all three question-answer cases finish **without a follow-up zeus_say**, so a new card cannot mask the release. Happy is an extra live mood check; all eight avatar states appear in this run.

## Timestamped state / row transcript

Each line is a changed presentation or native lifecycle; unchanged polling samples are omitted. The raw scrubbed JSON retains all sampling data and milestone triggers.

| t (s) | Avatar | Detail / trigger | Thread activity | Managed state |
|---:|---|---|---|---|
| 0.344 | idle | — | none | off |
| 0.628 | idle | — | none | starting |
| 13.418 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 13.903 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 13.954 | talking | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 16.474 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 16.749 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 16.804 | happy | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 19.309 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 19.604 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 19.677 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 22.490 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.working) |
| 25.514 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 25.767 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 25.799 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 28.530 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 28.801 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 28.855 | talking | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 31.361 | waiting | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 31.386 | idle | answer | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 31.413 | thinking | — | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 31.541 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 31.932 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 31.982 | talking | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 34.485 | waiting | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 34.487 | idle | answer | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 34.522 | thinking | — | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.working) |
| 37.691 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 37.975 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 38.010 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 38.033 | talking | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 40.562 | waiting | — | none | running(Host.ManagedSessionStatus.Activity.working) |
| 40.564 | idle | skip | none | running(Host.ManagedSessionStatus.Activity.working) |
| 40.573 | thinking | — | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.working) |
| 43.600 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 43.617 | idle | panel | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 43.997 | thinking | send | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 44.085 | talking | panel closed | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 46.552 | alert | panel closed | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 46.581 | idle | panel | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 46.837 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 46.869 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 46.898 | working | SA1 explicit work | SA1 explicit work | running(Host.ManagedSessionStatus.Activity.idle) |
| 49.606 | working | SA1 explicit work | SA1 explicit work | running(Host.ManagedSessionStatus.Activity.working) |
| 52.609 | working | SA1 explicit work | SA1 explicit work | running(Host.ManagedSessionStatus.Activity.idle) |
| 76.908 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 77.183 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 77.240 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 77.299 | working | SA1 explicit work | SA1 explicit work | running(Host.ManagedSessionStatus.Activity.idle) |
| 79.302 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 79.913 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 79.946 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 82.728 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.unknown) |
| 85.804 | alert | Waiting for your answer | none | blocked(reason: "Bash command") |
| 85.832 | alert | Waiting for your answer | none | blocked(reason: "Bash command") |
| 86.165 | alert | Waiting for your answer | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.unknown) |
| 86.362 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 86.648 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 86.692 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.idle) |
| 88.783 | thinking | — | Claude is thinking… | running(Host.ManagedSessionStatus.Activity.unknown) |
| 91.827 | alert | Waiting for your answer | none | blocked(reason: "Bash command") |
| 94.832 | idle | — | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 94.834 | sleeping | quiet | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 95.097 | thinking | send | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 95.158 | talking | quiet hours | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 97.651 | waiting | quiet hours | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 97.672 | sleeping | skip | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 97.703 | thinking | quiet hours | Sent to Claude… | running(Host.ManagedSessionStatus.Activity.idle) |
| 97.865 | sleeping | quiet hours | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 97.875 | idle | quiet | none | running(Host.ManagedSessionStatus.Activity.idle) |
| 98.253 | idle | own | none | off |
| 98.649 | thinking | send | Sent to Claude… | off |
| 98.728 | thinking | — | Claude is thinking… | off |

## Findings and fixes

1. **Fast managed turn missed by polling:** baseline fast Read/no-say stayed thinking for 20.626 s after a positive native idle prompt. Fixed run: 2.630 s. A new native Claude completion footer, scoped to its completed user turn and a fresh positive idle sample, ends an implicit row even if no working sample was captured. Old footer repaints and an echoed user message do not qualify. Unrecognized/native non-Claude formats retain the existing working/grace fallback.
2. **Explicit TTL extended:** a managed working sample changed the requested 30-second activity lease into a five-minute deadline. The baseline probe stopped after 45 seconds without release in this scenario (before.json contains the extended deadline). Working screen evidence now refreshes implicit activity only; explicit thinking/working keeps its original TTL. The live TTL gate above measures expiry to idle, while auto proves an early explicit release.
3. **Cross-review scheduler scope:** PC1's recorded Claude scheduled task has its own `Running scheduled task` start and footer without a new user prompt. That completion is rejected rather than attributed to the older user delivery. A fake-clock regression uses the recorded native ANSI screen and verifies a later user prompt resets the scope. See claude-scheduled-idle.json (platform PC1 provenance); no cron is created in the live SA1 run.

## Connect-your-own gap — proposal only

The same private real Claude/bridge was detached from managed observation and completed Read without zeus_say. At the native prompt it still showed **thinking / Claude is thinking…**. The full 305.020-second observation released only at the stale deadline, **299.894 s after the native prompt** (own-window.json; its clock is independent of the primary run). No own-session screen is consumed by the production runtime. The probe alone reads its private pane to measure this limit.
Proposed cheapest reliable Claude signal: add a launch-only Stop hook to the generated advanced launch command, sending a session-scoped, response-token-correlated turn-ended notification over Zeus's existing local bridge. It should end only that implicit response, without ending an explicit TTL or a newer response, and handle interrupts/errors separately. No saved agent config edits. The official [Stop hook reference](https://code.claude.com/docs/en/hooks#stop) documents turn completion; the [CLI --settings flag](https://code.claude.com/docs/en/cli-reference) permits session-only settings. This is a proposal, not implemented or live-proven here. A push-written receipt, next-tool-call gap or shorter stale timeout cannot establish completion during a long quiet turn.

## Scope, verification and reproduction

Live proof is Claude 2.1.299 only. No live Codex/OpenCode claim: the new completion parser is Claude-specific, while TTL preservation applies to all managed agents. Platform's SA2 owns their live completion probes; PC1 supplied recorded native classifier fixtures. An offscreen/long-output Claude turn without a recognizable user-scoped footer may still need the existing 20-second idle grace if working was missed. Multiple concurrent scheduled/native work needs a proper turn identity for stronger correlation.

Fake-clock regressions cover old/new same-minute completion footers, user echo, indented content, missing footer, scheduler scoping, no resurrection, and explicit TTL versus idle/working samples. The existing state, question, unread, quiet-hours and override tests remain green.

PM contract follow-up: §10.8 should describe managed positive-idle completion evidence/working sampling and the conservative grace, alongside preserving explicit status TTLs. Shared/CONTRACT were not edited.

```sh
scripts/build.sh
python3 -B Zeus/App/Tests/SA1LiveProbe.py --own-seconds 305 --record-fixtures
scripts/test.sh
```

probe.json is the primary run; before.json is the pre-fix capture; own-window.json records the full unmodified advanced-session stale window. Private helper/socket cleanup is checked independently. No automatic probe runs as part of test.sh.
