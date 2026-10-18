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

## Verification so far

- Eight Python tmux-hygiene tests pass, including a real private server with its
  socket and root removed before cleanup, and PID-reuse/default-server controls.
- Fourteen live-gate offline tests pass.
- A standalone compilation of the production isolation guard allows a HOME child
  and refuses a sibling, prefix sibling, symlink escape, missing HOME, and default
  tmux. Swift files parse successfully. App regressions cover saved-folder startup,
  restart, direct tmux launch without any process call, and invalid probe flags.
- Full app/build/live gates await the coordinated heavy slot; they are not claimed
  by this checkpoint.

Cross-owner edits authorized by appdev: composer startup in `ZeusApp.swift` and
`ComposerGrowthProbe.swift`; paired scratch-folder paths in `SA1RuntimeHost.swift`,
`SA1LiveProbe.py`, `ConnectOwnLiveTests.swift`, and `ManagedSettingsLiveTests.swift`.
The separate FX9 commit `74288a9` changes only the learning-story public AX walker;
appdev adopted it and reports the exact View-button regression passing.
