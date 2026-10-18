# FX17 — safe ordinary restart and visible menu confirmations

Branch: `appdev/fx17-safe-restart`.

Ordinary Restart requests a restart of the applied configuration through the existing settings-application path. It keeps the native conversation ID, waits for a positively idle/empty pane and the delivery/prompt guards, and repeats the native capture before stopping. A waiting request has Cancel in Settings and the menu. Crash recovery satisfies a pending ordinary restart instead of restarting twice.

Immediate recovery is a separate confirmed Restart Now action, available only for a dead process with a resumable native identity or the same blocked prompt after 120 seconds. The capability token scopes the confirmation to the pane lifetime and blocked fingerprint. Execution revalidates the token, ownership and current blocked screen after awaits. A different prompt starts a new waiting window. Cancel owns focus and Escape.

Every menu-produced managed confirmation now opens Settings at its confirmation target, including deferred switches and setup restarts. The regression enumerates every confirmation case.

## Ownership

- Platform authorized the minimal controller/capability changes and focused runtime regressions; read-only review found no blocker and requested fingerprint-window/stale-confirmation coverage.
- Designer approved both recovery confirmations and the existing agent-named waiting copy. Specs `faf0fc6` and `7644a72` adopted as `8e109ca` and `0a518c8` (MANAGED.md). Designer approved the minimal cross-owner `ZeusManagedStatusPanel.noteAction` addition and its package test; it uses the existing link focus/activation behavior. Final six Settings renders approved.
- PM-owned CONTRACT §11 needs the same ordinary-safe-restart / explicit-recovery policy and the optional `ManagedRestartRecovering` capability recorded at merge.

## Verification

Rebased onto FX18 merge `7ebb86e` before final gates.

- Focused: 13 tests / 3 suites passed (safe restart, presentation, real private-tmux lifecycle), 13.500 s. Earlier focused coverage of existing settings/restart/model suites passed; the native lifecycle fixture needed a positively bounded idle composer before ordinary Restart.
- `scripts/build.sh`: passed, no compiler warnings (Xcode prints its existing multiple-destination selection notice).
- `scripts/check-public.sh`: passed.
- Six native Settings renders: `build/fx17-renders`, light/dark × waiting/long-blocked/dead, approved by designer. Waiting has inline Cancel, Restart dimmed; recovery has Cancel focused/Esc, exact warning, and no duplicate Start action.
- `scripts/test.sh`: passed, 1,253 app tests / 254 suites in 576.319 s (1,214 passed, 39 expected opt-in/environment skips, zero failures); 277 package tests plus offline tests passed. Tmux hygiene found no new shared-directory entries or orphan fixture servers.
- `scripts/live.sh --quick`: passed 26/26 rows, no skips, 596.55 s; E2E 28/28. Private tmux hygiene passed. Evidence retained under `build/fx17-evidence` (including the scrubbed live receipts), renders under `build/fx17-renders`. All task build output was under `build/tmp/fx17/` through temporary aliases. The aliases and `build/tmp/` were removed after the gates; requested renders and logs are retained separately.
