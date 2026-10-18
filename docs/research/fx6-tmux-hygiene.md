# FX6-P — test socket hygiene

Both remaining named-server fixtures (P4 `TmuxIntegrationTests` and P7
`E2ETmuxTests`) now use `PrivateTestTmuxRunner`: an explicitly addressed
`-S /private/tmp/ztmux_<UUID>/sock`, no tmux config, and deferred `kill-server`
plus scratch-directory removal. Defers are registered before constructing
other fixtures, so a setup failure also cleans up. The failure-path regression
starts a real private server, throws, and checks the directory and server are gone.

A repository search of Swift/Python/shell tests, scripts and research probes found
no other `tmux -L` launch. The remaining `"-L"` is an intentionally invalid pane
value in `StatusStripNativeTests`. Existing live probes use explicit private
sockets and their cleanup paths remain unchanged.

`test.sh`, `e2e.sh` and `live.sh` now run inside a read-only shared-socket inventory
check. It compares names and device/inode identities before and after the command
in `/private/tmp/tmux-<uid>` and any explicitly configured `TMUX_TMPDIR`. A new or
replaced entry fails the command; removals are allowed. It never connects to or
removes sockets. A failed test command retains its failing exit status. Four
Python regression tests cover absent directories, unchanged entries, new/replaced
entries, removals, failure propagation and a command creating an entry in a
scratch shared-directory fixture (which the guard reports but does not remove).

## One-time cleanup — 2026-10-17

Only socket nodes with the task's four prefixes were candidates. For each:

1. `tmux -S <exact path> has-session` failed (bounded to two seconds).
2. A direct Unix socket connection returned `ECONNREFUSED`; success, a timeout or
   any other error would have preserved the candidate.
3. Device, inode and mode were rechecked immediately before unlinking.

Removed 301 verified-dead sockets: 284 `zeus-p7-`, 7 `zeus-p4-`, 4 `zq1codex`,
6 `zf2codex`. No server was killed by this cleanup. `default` and all nonmatching
entries were excluded from probes and deletion; their inode identities were
verified unchanged afterward. Execution details are in ignored
`build/fx6-cleanup.json`; the one-time cleanup script is deliberately not installed
as a routine test cleanup command.

## Verification

- Python hygiene regressions: 4 passed.
- Shell syntax and `git diff --check`: passed.
- Swift/build/full-suite results pending the appdev heavy-slot release.
