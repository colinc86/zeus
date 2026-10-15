# LG2 — full-suite saturation

## Root cause and attribution

Native test windows used AppKit's automatic show/hide transforms. These create
`_NSWindowTransformAnimation` objects whose `_runBlocking` method occupies a
user-interactive dispatch worker. In the affected host they remain blocked in an
AppKit run loop after the test finishes. The prior ordinary appdev sample
(`build/lm2d-standard-test-sample.txt`) has **64** such worker stacks and reports
the dispatch soft limit. Async fixture work then cannot run promptly; managed
`eventually` checks report `.deadline` even though their controller clocks are fake.

The quiet-machine LG2 trace identifies the animation subclass directly, without
changing controller behavior. It recorded 68 transform starts before stopping
the diagnostic run. Its intermediate one-second sample contains 34 blocked
animation workers; the earlier 64-worker samples establish the saturation limit.
This is native **window motion**, not the Zeus pixel renderer or agent timing.

### Isolated measurements (one process per selected test)

| Fixture | Native transform starts before | After static-host policy |
|---|---:|---:|
| `A12AccessibilityTests.auditNativeTrees` | 14 | 0 |
| `privateAppPickerAnnouncesAddedAndAlreadyPrivateButNotCancel` | 2 | 0 |
| `managedConfirmationsFocusLaterOrKeepRunningAndEscapeKeepsTheConversation` | 4 | 0 |
| All 10 `A12AccessibilityTests` | 60 | 0 |

The after counts come from the complete A12 suite: no transform starts in any
of its tests. All accessibility assertions pass. Logs are under `build/lg2/`:
`a12-tree-motion.log`, `a12-picker-motion.log`, `a12-confirmation-motion.log`,
`a12-baseline.log`, `a12-default-off.log`, and `static-host-focused.log`.
The 20-test A12/peek/SA2 run also has zero transform starts and passes.

`PeekSizingTests` was a separate resource issue, not the persistent-animation
source: it constructed 768 panels in one synchronous method and logged an
excessive live-window warning. Its isolated thread count was 9 before / 5 at
return / 61 after two seconds; a longer observation drained to 5. No native
transform starts were recorded. Each matrix cell now drains an autorelease pool
and detaches its host before closing. All 768 combinations and their explicit
0/0.5/1 reveal fractions remain covered.

## Changes

- `TestHostDefaults.m` registers `NSAutomaticWindowAnimationsEnabled = false`
  at **test-bundle startup**. Registration is process-local; no preferences are
  written. Production app targets do not include this file. A selected motion
  test can opt in with `TEST_RUNNER_ZEUS_TEST_WINDOW_ANIMATIONS=1`.
- Native SwiftUI fixtures use `TestHostingView`: `zeusAnimationsActive = false`,
  disabled SwiftUI transactions, and zero-duration/no-implicit-animation layout
  by default. `animationsEnabled: true` explicitly preserves deterministic peek
  reveal coverage. Replacing a root preserves the policy. Three regression
  tests cover defaults, opt-in, and root replacement.
- The real S3 fixture awaits private-process cleanup instead of `Thread.sleep`
  or synchronous `waitUntilExit` on the main actor. Process startup/exit still
  uses bounded wall time; it cannot be driven by a fake controller clock.
- The E2E suite already uses `.serialized`; its builder now also chains
  Debug/Release build tasks across actor suspension points. The Python live
  hosts hold one worktree-local, close-on-exec file lease through cleanup, so
  independent probes cannot overlap. An offline two-process regression verifies
  blocking, release at exit, and same-probe reentrancy.
- Managed unit fixtures retain `TestRuntimeClock`. The shared bounded
  `eventually` remains **three seconds**; errors now include the caller's file
  and line. No production timing, retry, assertion, or scheme concurrency cap
  was changed.

## Reproducing the diagnostic

The temporary private-method tracer is retained only as
`docs/audit/harness/LG2AnimationTrace.m`, outside every build target. To repeat
attribution, temporarily copy it into the test target, regenerate the project,
and select a single native test with `TEST_RUNNER_ZEUS_TEST_LG2_TRACE=1` and
`TEST_RUNNER_ZEUS_TEST_WINDOW_ANIMATIONS=1`. Omit the latter for the fixed count.
Remove the tracer before ordinary gates. Test selection requires the Swift
Testing method's parentheses, e.g.
`-only-testing:ZeusTests/A12AccessibilityTests/auditNativeTrees()`.

No user window capture, real agent configuration, keychain, or default tmux
server is involved. Temporary diagnostic instrumentation has been removed from
ordinary tests.

## Verification

- Isolated A12/peek/SA2: 20 tests pass, zero native transform starts.
- Final host-policy/SA2/shortcut/live-fixture selection: 12 tests pass; real-agent
  opt-ins remain skipped, not falsely reported as executed.
- `python3 -B Zeus/App/Tests/Runtime/LG2LiveHostLeaseTests.py`: 1 test passes.
- Full-suite and load results are recorded below.

The first complete post-fix run reached all 1,001 app tests in 208.751 seconds,
with no managed deadline cascade. Its two failures were a pre-existing Phase D
headless source-list omission (`LearningStorageRecovering` and
`LearningStorageError`). P13 and Python headless builders now copy their actual
recovery/encryption declarations; no key provider is instantiated. The failed
preflight is retained as `build/lg2/preflight-missing-host-sources.log` and is
not counted toward the three consecutive passes.

## Second resource leak exposed by the longer run

After the source-list fix, the full suite **passed** (1,001 tests, 310.324 s).
A late sample nevertheless showed hundreds of `ZeusLink.accept` workers still
blocked in `Darwin.accept`, with no animation workers. A separate private Unix
socket probe confirmed `shutdown(listeningFD, SHUT_RDWR)` returns errno 57
(`ENOTCONN`) here and leaves `accept` blocked; `close` finally releases it.
`ListeningSocket.run` retained itself until that blocked call returned, while
`stop` deliberately deferred `close` to the worker. Thus stopped test listeners
accumulated for the lifetime of the app-test process. This also affects real
repeated server start/stop, so a test-only timeout or concurrency cap is inadequate.

`ListeningSocket` now uses a nonblocking `DispatchSourceRead` accept loop. Idle
listeners consume no worker. Stop cancels the source and its cancellation handler
closes the descriptor after any event handler has finished; accepted channels
retain their previous blocking I/O semantics. The stop-before-run path closes
immediately, and inode-scoped unlinking remains intact. No public API changes.
Two package regressions cover 64 idle listener stop/release cycles without any
connection and immediate socket-path replacement. All 22 ZeusLink tests pass,
including reconnects, handshake timeout, receipts, and hook clients. The final
three-run sequence starts after this additional fix.

The first final-code attempt (after the listener fix) completed all 1,001 app
tests but failed one `ManagedFlowE2ETests` initial check-in: its fake agent had
exited and the controller reported backoff. Its script called `zeus_say`
immediately after MCP initialize, which does not establish the asynchronous
Zeus transport. The fixture now waits for the exact managed parent/session binding
before permitting that first call, and records native-agent exceptions for future
phase failures. All delivery, block/clear, crash/resume, and stop assertions remain.
It passes alongside A12 (11 tests) and alongside all three managed-tmux agent cases.

`NativeProcessTestGate` now serializes real E2E/tmux/managed fixtures **across**
suites, suspending waiters on the main actor and releasing only after private
cleanup. The previous per-suite `.serialized` annotations did not provide this
cross-suite exclusion. A regression verifies three independent fixture bodies
never overlap. Fake-host unit tests remain concurrent. The final sequence starts
again after these fixture changes (1,002 app tests; 249 package tests).

## Final proof on 72653c8

Three consecutive ordinary `scripts/test.sh` runs passed on the same code revision,
with no competing xcodebuild. Each ran **1,002 app tests in 207 suites**, **249
package tests**, and the **16 release + 10 live-gate offline fixtures**. The app
result summaries report 978 passed, 24 normal opt-in skips, zero failures; these
skips are not claimed as live-CLI proof. Xcode pruned the oldest result bundle;
all three complete command logs and successful supervisor exit remain available.

| Run | App-test duration | Result | Log |
|---|---:|---|---|
| Quiet 1 | 410.739 s | Passed | `build/lg2/full-1.log` |
| Quiet 2 | 337.521 s | Passed | `build/lg2/full-2.log` |
| Quiet 3 | 366.152 s | Passed | `build/lg2/full-3.log` |

The quiet sequence ran from 07:30:18 to 07:52:13 UTC on 2026-10-15.
`quiet-2-summary.json` and `quiet-3-summary.json` retain the surviving xcresult
summaries. Final process samples (`final-resource-sample.txt`,
`final-late-sample.txt`) have zero blocked NSAnimation worker stacks and zero
blocking accept syscall stacks.

`scripts/build.sh` passed. The independent cold build also passed; its warnings
are in unchanged CharacterSettingsView, PrivacySettingsView,
AppearanceSettingsView and ManagedTerminal (existing Sendable conversion / unused
binding warnings), plus the existing ambiguous macOS destination notice. LG2
introduces no new compiler warnings. No scheme-wide concurrency cap was needed.
Real process startup remains bounded wall time because a fake clock cannot start
an OS process; controller time-dependent logic retains its injected clock. The
shared unit-test `eventually` deadline remains three seconds.

The fourth ordinary full run overlapped a cold `scripts/build.sh` in an isolated,
detached worktree at the same revision, with separate DerivedData and SwiftPM
products. **Both exited zero**. The full suite again passed 1,002 app tests in
207 suites (399.681 s), 249 package tests and all offline fixtures. Its xcresult
reports 978 passed, 24 skipped, zero failures (`build/lg2/load-summary.json`).
The full command ran 07:53:47–08:01:29 UTC; the build started 07:54:18 and its last
successful output was written at 07:55:23 UTC, overlapping the app-test process.
Evidence: `full-load.log`, `load-build.log`, timestamp and exit files under
`build/lg2/`. The disposable worktree is removed after proof. This proves one
parallel cold build, not arbitrary concurrent full-suite or render loads.

No full native-agent live gate is claimed by LG2. Existing opt-in tests retain
their normal skips; the focused and full runs above exercise ordinary isolated
fixtures. Production animation behavior is unchanged: static defaults are in the
test bundle only. No contract change is requested.
