# LG2 — full-suite saturation investigation

Status: investigation in progress; no proof runs yet.

## Evidence before the isolated runs

The prior ordinary appdev sample (`build/lm2d-standard-test-sample.txt`) contains **64** `NSAnimation._runBlocking` worker stacks. This was a non-render-opt-in run. Each worker is parked in an AppKit animation run loop on the user-interactive dispatch root queue. The main thread continues pumping XCTest/AppKit. These stacks establish saturation, but do not identify the creation site.

The earlier render-enabled sample also caught synchronous Vision OCR on the main actor; that OCR fixture has since moved its work off the main actor. Removing render opt-in did not remove the animation-worker failure.

## Candidates and timing audit

- `PeekSizingTests.renderedPeekFitsWindowAcrossLinesFontsTitlesOptionsAndTailEdges`: 768 native panel/hosting-view pairs (2 fonts × 4 line counts × 2 title states × 2 option states × 4 tail edges × 3 reveal fractions). Explicit animation environment is enabled. Fractions are deterministic coverage and must be retained. Attribution awaits isolated measurement.
- Managed unit controller timing uses `TestRuntimeClock`; the shared three-second `eventually` helper is an asynchronous scheduler/readiness bound, not the controller clock. Increasing this bound alone would hide the saturation.
- `ZeusE2ETests` already has `.serialized`. `RuntimeHostBuilder` coalesces same-configuration builds, but its actor can run different configurations across suspension points.
- `ManagedSettingsLiveTests` has synchronous `Thread.sleep` calls in private-process teardown. Its real-process launch/exit waits cannot be replaced by advancing a fake controller clock; teardown can instead await bounded process exit without blocking the main actor.

## Measurement plan

Run each selected native fixture alone with the opt-in LG2 audit: log thread counts before/after and after finite animations settle, plus native animation class/creation stack. Do not infer attribution from total thread count alone. Hold these runs until the PM main-checkout xcodebuild exits.

## Current gate reservation

On 2026-10-15, the PM main-checkout `xcodebuild` PID 82112 and app-test host PID 85314 remained active after 15 minutes (both sleeping, xcodebuild 0% CPU). No LG2 build/test was started concurrently and neither PM process was stopped. The isolated audit is opt-in (`ZEUS_TEST_LG2_AUDIT=1`, select `LG2NativeWorkerTests`); it has not yet been compiled or run. Three quiet full passes and the parallel-build load check remain outstanding. No production fix or timeout change is included in this checkpoint.
