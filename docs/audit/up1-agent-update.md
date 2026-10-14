# UP1 — installed agent update and safe restart

The managed Claude updater footer now produces one quiet, durable thread notice and an explicit
restart action. Detection requires Claude's cursor-bound, bounded composer and the installed-update
footer below its lower rule. History, draft text, malformed metadata, permission dialogs and other
agents do not count. There is no recorded equivalent installed-update footer for Codex/OpenCode,
so their detection remains false. Two consecutive positive samples raise the flag; one negative
sample, Stop, process replacement or restart clears it.

The thread line is `Claude Code has an update · Restart assistant`. It does not add a card, badge,
peek, sound or reveal animation. Questions suppress the line and disable its action. Active notice
identity is saved independently of clearable history, so Later, history clearing, relaunch and the
200-notice retention cap do not repost the same edge. A subsequent observed false → true edge or
new managed conversation can post again. Quitting/detaching Zeus is not treated as a sampled
clear edge in the agent it leaves running.

Settings uses its existing status-box note and Restart button: `Claude Code has an update. Restart
to use it; the conversation is kept.` Restart becomes primary in running/starting, and uses the same
safe update path as the thread. There is no second Restart button. Unrestricted modes ask again with
Later focused/Esc. A deferred agent/folder choice cannot hijack the update restart.

The explicit `.agentUpdate` request passes through `ManagedSettingsApplying`: it skips only the
unchanged-settings early exits, then reuses native idle/empty-composer recaptures, ownership/lifetime
checks, native resume identity and in-flight-delivery gates. Busy requests say `Restarting when Claude
Code is idle…`. Nothing starts without a click. The controller reports the completed request UUID only
after a successful resume launch; only that receipt earns `Restarted`. A vanished footer alone removes
the action without a resolved claim, because Claude also hides the footer during permission prompts.

## Ownership and integration

The task explicitly authorized the small platform-owned change. Modified platform files are:

- `Zeus/Agents/ManagedPaneClassifier.swift`
- `Zeus/Agents/ManagedSessionController.swift`
- `Zeus/Agents/ManagedSettingsApplying.swift`
- New isolated `Zeus/App/Tests/Runtime/ManagedAgentUpdateTests.swift`

No connector, Shared or ZeusDesign changes. The optional `ManagedAgentUpdating` capability lives
beside the existing runtime-owned settings capability and is forwarded by `ZeusRuntime`.
PM can document it in CONTRACT §11.7: pending flag, conversation nonce, completed restart request
UUID and an explicit safe-resume update action. Shared/CONTRACT remain PM-owned.

Platform's read-only review of `b4da419` found no blocker in the Agents delta. Designer reviewed the
initial render and copy, then approved the revised `b4da419` status box/confirmation and conservative
completion copy. Restoring/removing an action separately publishes availability so an open thread
refreshes even when the durable notice text did not change.

## Verification

- Focused classifier/controller/presentation/S3 run: 32 tests in four suites passed before the final
  dismissal/relaunch and quit/adoption regressions were added.
- Final `scripts/build.sh`: passed, no new warnings (only the existing ambiguous macOS destination warning).
- Final `scripts/test.sh`: **16 release/appcast + 233 package + 772 app tests in 159 app suites passed**,
  including dismissal/relaunch, quit/adoption and restored-action observation. App run: 276.789 seconds.
  Default suite keeps the three A12 unlocked-keyboard cases opt-in; their separate main results are below.
- Native Settings render and AX activation: [fixture](../../TestFixtures/live/up1/README.md).
- No fresh live CLI updater/restart was performed. The terminal screens are PC1's real recorded
  frames; safe restart is proved with a production controller, isolated host and fake clock.

## PM-requested A12 unlocked keyboard check on main 04179c9

UP1 was checkpointed, this worktree temporarily checked out **detached `04179c9`**, and then returned
to `appdev/up1-agent-update`. These results are from main, not UP1:

- **PASS** `privacySheetKeyboardDefaultsToNotNowAndTabSpaceReturnWorkOnce`.
- **PASS** `nativeKeysActivateThemeCheckboxNoticeStripAndGhostSlider`.
- **FAIL** `nativeChoiceAndCheckboxUseSpaceAndLeaveReturnToTheWindow`:
  `Packages/ZeusKit/Tests/ZeusDesignTests/ZeusKeyboardAccessibilityTests.swift:125`.
  Unmodified Space on the focused `Codex. Installed` row left `state.selected == "claude"`;
  the expected value was `"codex"`. Return/Option-Space guards and checkbox checks passed.

The app's A12 suite passed all 10 tests with the two active-key cases enabled; the ZeusDesign suite
passed its three always-on checks and failed that one active-key case. No retry and no main edits.
Designer agrees this is a real choice-row keyboard defect and can take an A12 follow-up when assigned
(after MB1). It remains outside UP1. Logs: `build/a12-main-live-app.log` and
`build/a12-main-live-package.log` (worktree-local, ignored).
