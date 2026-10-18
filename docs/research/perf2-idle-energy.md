# PERF2 — idle energy attribution

Resting animation and managed-pane subprocess work were the largest measured contributors. The changes reduce visible idle app CPU and wakeups; the managed CPU target remains partially unmet. No performance result is inferred from timer frequencies alone.

## Measurement isolation

The performance launcher uses a fresh `zperf_` home, a private tmux directory, credential-free app settings and in-memory journal/rules/ratings keys. It refuses binaries without the isolated Debug entry point. No real agent or workspace capture starts. The optional managed fixture runs a synthetic idle CLI through the production controller on a private socket. A requested probe with an invalid environment exits before production dependencies can be constructed.

The app, its production runtime and bridge still start normally. Visible/hidden-avatar and idle-bridge runs separate rendering from delivery overhead. Frame-counter evidence is collected separately because the diagnostic counter itself wakes once per second. CPU is measured from cumulative process time; interrupt and package-idle wakeups come from `proc_pid_rusage`. Package-idle counts depend on other machine activity, so both counters are retained.

## Static inventory (not measured attribution)

| Source | Active cadence / idle behavior |
|---|---|
| Avatar | Resting states use declared rates; active procedural effects capped at 12 Hz; stops when inactive |
| Managed pane | Once per 3 seconds while attached; subprocess work may add wakes |
| Own-session pane | Once per 3 seconds only while tracking selected assistant activity |
| L1 activity | Workspace notifications plus 30-second input-age poll while recording |
| L2 focus | 3-second sample while enabled |
| L3 screen | 1–30-second scheduling check while enabled; capture separately bounded |
| L4 typing | 1-second state check while enabled; event tap for keys |
| Morning presence | 30-second timestamp check when enabled |
| Learning boundaries | Next applicable deadline, no unconditional periodic tick |
| Bridge socket | Event-driven read/write readiness |
| Sparkle | Disabled in Debug; production updater cost unmeasured |

## Results

Measured on an M1 Pro, macOS 27.0, unlocked console, Debug build, closed conversation and no learning capture. Each CPU interval uses cumulative process time divided by elapsed wall time (one-core percent), for the app process. Short-lived tmux clients and the synthetic CLI are not included in that CPU figure; the separately reported bridge is measured as its own process. No concurrent build or test ran during the final intervals. These fixtures did **not** reproduce the reported 125 idle wakeups/s; they establish a narrower baseline, not a reproduction of the user's exact enabled-feature configuration.

| Configuration | CPU before | CPU after | Interrupt wakes/s before | After | Package-idle wakes/s before | After |
|---|---:|---:|---:|---:|---:|---:|
| Visible, managed synthetic idle, 60 s | 1.9823% | 1.2826% | 10.9276 | 5.6969 | 0.1832 | 0.0167 |
| Visible, no managed session, before 30 s / after 60 s | 0.9996% | 0.6996% | 10.9622 | 5.6971 | 0.1666 | 0 |
| Hidden, no managed session, 30 s | 0.0000% | 0.0000% | 0.1666 | 0.1999 | 0 | 0 |

Batching tmux alone measured 1.4326% CPU / 11.2445 interrupt wakes/s before the renderer change. CPU is not inferred from wakeup counts. Package-idle wakeups are particularly sensitive to the rest of the machine being awake.

## Attribution and changes

| Source | Measured contribution / evidence |
|---|---|
| Avatar | Visible baseline 10.9622 vs hidden 0.1666 interrupt wakes/s (~10.80 additional). Main-thread samples show sprite rasterization and layer commits. Resting Zeus now requests 6 Hz rather than 12 Hz. |
| Managed pane | Hidden managed baseline 0.9165% CPU / 0.6332 interrupt wakes/s, compared with hidden unmanaged 0% / 0.1666. Samples show subprocess launch and temporary-file work. This hidden interval approached a later build, so it is attribution evidence rather than the clean final bound. |
| Bridge | A separately measured connected, idle real zeus-mcp used 0% CPU / 0.0981 interrupt wakes/s; event-driven socket readiness. |
| L1 activity / L2 focus | Zero capture timers in this fixture: all policies disabled and capture source locked/untrusted. Active-feature cost was not measured. |
| L3 screen | Disabled; no capture/OCR/model calls. Active-feature cost was not measured. |
| L4 typing | Disabled; no event tap. Active-feature cost was not measured. |
| Learning boundaries / presence | Startup diagnostic confirms no shell deadline. Managed first-activity presence can check timestamp age every 30 s; it is included in managed aggregate, not independently isolated. |
| Sparkle | Debug build disables its controller. Release updater contribution is unmeasured; no claim that it explains or fixes the reported 125/s. |

Known-pane inspections formerly launched three tmux clients for exact session ownership, pane membership, and process metadata. They now collect the same three queries in one client, retaining the missing-owner recovery path, exact names, before/after capture checks and kernel process lifetime validation. A normal polling cycle inspects once and capture inspects before/after its two read commands: 11 client launches become 5, by code-path count. Polling stays at three seconds. Changing that cadence would delay permission/readiness/activity detection and is outside this behavioral fix.

Resting animation sampling follows declared frame/particle rates instead of the 12 Hz procedural floor. Timed accents and sleeping emotes use that grid. Zeus idle/sleeping are 6 Hz, Pumpkin idle remains 8 Hz, and a custom 24 fps regression preserves 24 fps. Unspecified smooth particles retain 12 Hz. Other states and Reduce Motion continue to honor their own effects. The driver still renders using wall time and immediately reconfigures state, Reduce Motion and active changes; no driver/UI context changes were needed.

The managed aggregate misses the strict 1% CPU target (1.28%, about 35% below baseline), while passing both 20-wakeup/s bounds. Remaining managed cost includes process creation and independent before/after lifetime checks; retaining those checks and responsive three-second sampling takes precedence over meeting a numeric bound by slowing detection. The script reports this CPU bound failure rather than accepting it silently.

## Regression and safety coverage

- `scripts/perf.sh --max-cpu 1 --max-wakeups 20 --max-idle-wakeups 20` fails any exceeded or unavailable measurement.
- `--frames` is a separate animation proof because its diagnostic counter adds one wake/s. It requires changing native avatar pixels and layer/driver identity agreement.
- Probe launch validates disposable HOME, isolated tmux paths, and config-variable containment before production startup. Settings use no credential store; journal/rules/ratings use a fixture-only in-memory key. Even preseeded L2–L4 consent is cleared; the source reports locked. Invalid requested probes cannot fall back to normal startup.
- Known-pane batching tests retain exact session/owner/membership rejection and missing-pane recovery before metadata lookup; real private tmux and recorded Claude capture suites pass.
- The exhaustive equal-signature/equal-pixels test retains its 12 Hz timeline and adds an eight-second 6 Hz resting timeline.

Final native animation proof: 7 → 85 pixel changes across 14 diagnostic samples, interval 1/6 s, all layer contents matched the driver, console unlocked. The visible low CPU result is not a frozen/occluded avatar.

One full run was deliberately interrupted after review found a missing-pane fallback ordering regression in the new batching code. The original early return was restored and covered before the final run; no test deadline or assertion was relaxed.

## Reproduce

Use a Debug build with the isolated probe entry point. Keep other builds, tests and profiles stopped during each interval.

```sh
scripts/build.sh --for-testing
scripts/perf.sh --seconds 60 --label visible --max-cpu 1 --max-wakeups 20 --max-idle-wakeups 20
scripts/perf.sh --managed --seconds 60 --label managed --max-cpu 1 --max-wakeups 20 --max-idle-wakeups 20
scripts/perf.sh --hidden --seconds 30 --label hidden --max-cpu 1 --max-wakeups 20
scripts/perf.sh --frames --seconds 10 --label frames
```

The managed command currently fails only its CPU bound; that is the documented result, not an expected-pass regression threshold silently raised to fit it. Result JSON includes both wakeup counters and measurement context. The standalone visible and hidden commands passed their bounds.

## Verification

- `scripts/build.sh --for-testing`: passed, no new compiler warnings (existing ambiguous-destination warning only).
- Focused isolation/real-tmux/recorded-capture suite: 11 tests passed; final missing-pane/animation-transition suite: 14 passed.
- `scripts/test.sh`: 1,271 app tests / 259 suites passed in 562.714 s; all 277 package tests and offline gates passed. Tmux hygiene reported no new shared-directory entries or orphan managed fixture servers.
- `scripts/check-public.sh`: passed.
- Full `scripts/live.sh --quick`: all 26 rows passed in 595.93 s, including all real-agent scenarios and private-tmux E2E. No skipped rows; tmux hygiene clean.

Cross-owner work was authorized: DEBUG app/probe dependency injection and its isolation tests by appdev; resting renderer cadence and signature coverage by designer; app-side cadence transition regression by appdev. Designer's rendering specification commit was adopted, with their approved wall-time wording correction. No Shared seam or wire contract changed.

Task-owned `build/tmp/` output and aliases were removed before handback. Aggregate measurement results and verification counts are retained here; raw temporary homes, logs and traces are intentionally not retained.
