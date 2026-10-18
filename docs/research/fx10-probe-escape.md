# FX10: composer probe launch isolation

## Root cause and evidence boundary

The composer probe was an optional action inside normal app startup. Its guard
returned when the disposable environment was invalid **or managed settings were
enabled**. `ZeusAppDelegate.applicationDidFinishLaunching` then unconditionally
called `startAgentLink`. The controller read the saved `agent.managedSession`
configuration and launched its folder. A rejected probe therefore became a real
app launch rather than exiting.

The folder is persisted in `AppSettings`' UserDefaults domain. It is not resolved
from a security-scoped bookmark or `getpwuid` in the managed launch path.
A synthetic Foundation subprocess experiment used one unique throwaway defaults
domain across two different disposable HOME/CFFIXED_USER_HOME pairs: a folder
written under home A was returned under home B. Both domains were removed after
the experiment. Changing HOME is insufficient to isolate the preference domain.
Foundation's home APIs returned the disposable homes (with `/tmp` alias spelling);
`getpwuid` continued to identify the account home, but did not supply the stored
managed folder. No real app preference domain or agent configuration was read.
The historical five-day fixture directory was already deleted, so its exact saved
preference bytes cannot be recovered or claimed as directly reproduced.

## Changes

- Any composer-probe environment key selects the probe path, including an invalid
  flag. Invalid environments terminate; valid probes use a fresh synthetic
  preference domain, explicit card URL, disabled managed settings, and a credential
  store that cannot write. Neither path constructs the production runtime.
- Managed start, adoption, restart, new conversation, settings replacement, template
  writes, native discovery, and direct tmux create/launch validate the disposable
  HOME boundary. Symlinks and path-prefix siblings cannot escape. Restored agent
  profile paths must also stay inside HOME. A test/probe cannot use default tmux.
- Live fixtures whose project was a sibling of HOME now put it inside HOME. Paired
  Swift hosts and Python launchers use the same path. Create-default-folder already
  uses the supplied HOME; the new validation protects its fallback too.
- Process inventory finds explicit fixture tmux namespaces even after socket
  deletion. Cleanup snapshots exact PID/start-time identities and descendants,
  rechecks before each signal, and never signals a process group. Default tmux is
  excluded. GUI launch argv alone is insufficient: the fallback also requires a
  matching private open socket. Hygiene reports new orphan process lifetimes.

## Verification

- `scripts/build.sh --for-testing` and the final incremental `scripts/build.sh`
  passed. Warnings were confined to unchanged files and the existing destination
  selection warning; the changed sources introduced none.
- `scripts/test.sh`: **1,197 app tests / 243 suites**, **274 package tests**, and
  offline checks passed. App duration: **567.851 s**. The final Swift changes were
  covered by this run; subsequent changes were fixture launcher paths and the
  process-inventory parser, checked below.
- **31 focused Swift tests / 5 suites** passed: isolation, managed lifecycle,
  delivery/relaunch, and real private tmux for Claude, Codex, and OpenCode.
- **9 Python tmux-hygiene tests** and **16 live-gate offline tests** passed,
  including a real private server whose socket and root were deleted, PID reuse,
  default-server exclusion, and pane text containing a fake `-S` option.
- `test_composer_probe_isolation.py` ran the actual Debug app twice in new private
  homes. An invalid flag exited without creating card history; a valid flag ran
  the isolated shell. Both exited normally, with no managed-launch artifacts or
  fixture tmux servers. This also exposed Foundation's `/private/tmp` → `/tmp`
  spelling change under CFFIXED_USER_HOME; the guard now uses `realpath`.
- The complete `scripts/live.sh --quick` passed **25/25 probes, no skips**, in
  **359.47 s**, including **28/28 E2E scenarios**. The initial live run caught a
  paired CY1 launcher path missed in the first audit; its Python launcher was
  aligned with the Swift host, then the entire gate was rerun successfully.
- Final process inventory: **zero fixture tmux server lifetimes**. No default
  server or unrelated process was signaled. The public check passed.

Retained local evidence: `build/fx10-full.log`, `build/fx10-focused.log`,
`build/fx10-build.log`, `build/fx10-composer-proof.json`,
`build/fx10-live-quick.log`, and `build/fx10-live-summary.json`.
Task build aliases targeted `build/tmp/fx10/`. The embed build phase also reused
its existing `build/EmbeddedBridge` cache; that cache was removed during cleanup,
along with `build/tmp/` and all task build aliases. Retained files are logs and
small verification summaries only.

Cross-owner edits authorized by appdev: composer startup in `ZeusApp.swift` and
`ComposerGrowthProbe.swift`; paired scratch-folder paths in `SA1RuntimeHost.swift`,
`SA1LiveProbe.py`, `ConnectOwnLiveTests.swift`, `ManagedSettingsLiveTests.swift`,
`CY1LocalModel.py`, and `S3LocalResumeModel.py`.
The separate FX9 public AX walker edit was adopted by appdev as `847be08` and
passed the exact View-button regression. FX10 was rebased onto `e954dac`; the
original duplicate `74288a9` is not on this branch.
