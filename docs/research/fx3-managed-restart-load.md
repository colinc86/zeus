# FX3: managed restart under load

The fixture's `stopped; busy: true; pane: nil` is an intermediate restart state, not evidence that the action ended stopped. `perform(.restart)` awaits `stop()` and then `start()`. Stop publishes stopped before its asynchronous teardown; the queue keeps `isBusy` true until the action and pending actions finish. The original ten-second fixture wait can expire during that work. Diagnostic observation beyond that deadline showed all three agents completing successfully with the same native conversation; it did not find a lost restart action.

There was nevertheless a production defect amplifying the load sensitivity. On installed tmux 3.6a, `show-options -qv -t '=zeus' @zeus-owner` exits zero with empty output even when the session marker exists. Reading the same option using its immutable `$ID` returns the marker. `inspectPane` consequently entered interrupted-launch recovery on every healthy inspection, reading the environment, resolving the session again, and rewriting its owner. A restart made 99 subprocess calls.

The fix resolves exact session name, immutable ID and owner together with `list-sessions`. Only a genuinely missing marker uses recovery; a foreign marker is rejected even when the original recovery environment remains. Prefix matching is not used. Pane/process lifetime validation remains intact. Restart now uses 51 commands, with no unnecessary owner repairs. Neither production timeouts nor the fixture's ten-second deadline changed.

## Evidence

All probes used private tmux sockets, scratch directories, disposable HOME and fake native CLIs, without user configuration or credentials. No full suite was run; PM owns that gate.

- Private option-target probe: `=zeus` yielded empty; `zeus` and `$0` yielded the planted marker. Only the immutable-ID form is used for recovery writes.
- Instrumented original lifecycle passed quietly; Claude/Codex restart took 1.30/1.50 seconds and 99 commands.
- With 120 ms of asynchronous scheduling delay per restart command, the old implementation crossed ten seconds for every agent and then completed: Claude 16.627 s, Codex 15.979 s, OpenCode 16.059 s. Captured deadline states included starting with a nil pane. Full native-ID/readiness and foreign-pane assertions passed afterward. This was diagnostic observation, not a committed deadline increase.
- Fixed implementation, same injected delay and original ten-second wait: Claude 8.463 s, Codex 9.243 s, OpenCode 9.814 s; 51 commands and zero owner repairs for each. Targeted test passed in 45.483 s. Additional checks cover healthy marker reads, missing-marker repair, and foreign-marker rejection.

Logs: `build/fx3-trace-quiet.log`, `build/fx3-trace-delayed-before.log`, `build/fx3-trace-delayed-after.log`. Repeat verification: `build/fx3-trace-delayed-repeat.log`, two additional iterations of the same targeted test, passed all six agent cases in 75.701 s. Restarts ranged from 7.984 to 8.280 s, each with 51 commands and zero owner repairs. Together with the first fixed run, nine delayed lifecycle cases passed with unchanged deadlines. The targeted build passed with no new compiler warnings (only the existing AppIntents metadata message).

The opt-in reproduction is the targeted Xcode test with `TEST_RUNNER_ZEUS_FX3_DELAY=0.12`. The test wrapper delays only its own restart commands, records elapsed time/count/recent commands on failure, and does not load the machine with unrelated workers. The ordinary suite injects no delay.
