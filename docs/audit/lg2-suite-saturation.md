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
- Full-suite and load results are recorded below after the proof runs.

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
