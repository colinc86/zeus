# FX17 — safe ordinary restart and visible menu confirmations

Branch: `appdev/fx17-safe-restart`.

Ordinary Restart requests a restart of the applied configuration through the existing settings-application path. It keeps the native conversation ID, waits for a positively idle/empty pane and the delivery/prompt guards, and repeats the native capture before stopping. A waiting request has Cancel in Settings and the menu. Crash recovery satisfies a pending ordinary restart instead of restarting twice.

Immediate recovery is a separate confirmed Restart Now action, available only for a dead process with a resumable native identity or the same blocked prompt after 120 seconds. The capability token scopes the confirmation to the pane lifetime and blocked fingerprint. Execution revalidates the token, ownership and current blocked screen after awaits. A different prompt starts a new waiting window. Cancel owns focus and Escape.

Every menu-produced managed confirmation now opens Settings at its confirmation target, including deferred switches and setup restarts. The regression enumerates every confirmation case.

## Ownership

- Platform authorized the minimal controller/capability changes and focused runtime regressions; read-only review found no blocker and requested fingerprint-window/stale-confirmation coverage.
- Designer approved both recovery confirmations and the existing agent-named waiting copy. Spec `faf0fc6` adopted as `07dabe6` (MANAGED.md). No ZeusDesign changes.
- PM-owned CONTRACT §11 needs the same ordinary-safe-restart / explicit-recovery policy and the optional `ManagedRestartRecovering` capability recorded at merge.

## Verification

Results and render review will be recorded after the serialized gates finish. All task build output lives under `build/tmp/fx17/` through temporary aliases and is removed before handback; requested renders and logs are retained separately.
