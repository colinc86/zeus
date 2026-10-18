# FX7: long delivery pointers

Complete on `platform/fx7-long-deliveries`; required build, full test and full live gates pass.

## Read-only investigation of the reported two managed sessions

The apparent duplicate was inferred from `ps` command lines, which retain the initial
`tmux new-session -s zeus …` launch argv even after tmux becomes a server. Socket
inspection and the app's saved lease establish that these are **different servers**:

- The current real default server has exactly one session, `zeus`. Its owner marker,
  server PID, pane ID and child process match the app's saved `managed-session.json`.
- The older server belongs to a `zcomposer_*` private fixture socket namespace. That
  directory/socket has been deleted while the server and Claude child remain alive.
  The child launch configuration also points into that fixture directory. It is not
  a second session on the user's default server.

Only read-only `ps`, `lsof`, `tmux list-sessions` and selected lease fields were used.
Neither of these servers nor the user's assistant process was changed. **Do not add
production session reaping based on this evidence.** The older fixture is a separate
cleanup decision for the PM; ownership checks remain required for any proposed reaping.

## One-time managed fixture cleanup

Two `zmanaged_*` servers dated October 14/15 were verified from exact executable/argv,
owned scratch directories containing `agent.py`, and open socket identity. One retained
a fake Python agent; the other retained a dead pane. Each was stopped with `kill-server`
addressing its explicit private socket; `ps` verified both server processes exited.
No default socket or unrelated fixture namespace was changed.

Normal fixture teardown already attempted `kill-server`, but cannot run when the test
host is killed. The private fixture's simulated unrelated pane now watches the test
host lifetime and shuts down its own private server if that host exits. Normal cleanup
checks its exit status and retains the root on failure. FX6's read-only inventory guard
also detects newly orphaned `zmanaged_*` server processes, including unlinked sockets.

## Semantics

The full content remains in the durable ledger. A pointer is chosen only when the
pane cannot verify the original envelope. Pointer ownership is saved before paste,
so interrupted submission recovers that exact text without repasting. Exact-ID fetches
are recipient-scoped and reject erased/discarded/policy-disabled input. User/reply
fetches retain polling consumption acknowledgment; learning fetches require explicit ack.
A submitted pointer's Sent receipt records the full body without fabricating ack.

Expired requests leave a durable discard and Not sent notice, not a Sent journal row.
Already-submitted pointers preserve their existing Sent receipt when their retry window
expires. The old catch-up test uses two days rather than three because FX7 explicitly
expires reflections older than two local days; the new expiry regression covers that rule.

## Verification

- `swift test --package-path Packages/ZeusKit --scratch-path build/ZeusKit`: 274 package tests pass (`build/fx7-package-final.log`). Schema argument-list expectations were updated and the remaining tests searched for old lists.
- Focused app gate: 31 tests / 4 suites pass in 13.351 s (`build/fx7-focused-final.log`). Covers an 80×24 pointer, exact recipient-scoped fetch, full-body receipt without fabricated ack, size-only startup retry, expired requests and late acks, interrupted pointer recovery without repasting, existing multiline/draft guards, all three managed fixture lifecycles and parent-exit cleanup.
- `scripts/build.sh --for-testing` passes with no new compiler warnings (`build/fx7-build.log`, final test-only rebuild `build/fx7-build-e2e.log`).
- Full `scripts/test.sh` passes: 1,181 app tests / 239 suites in 505.194 s (1,145 passed, 36 expected skips, zero failures), plus 274 package tests, 16 release offline tests, 14 live-gate offline tests and five tmux hygiene tests (`build/fx7-full.log`).
- Public check and `git diff --check` pass.
- Real Claude 2.1.302: both `rf1` and `pa1-brief` pass at **120×40**, with the durable pointer flag asserted, exact-ID fetch and ack on attempt 1. RF1 writes both Notes files and proposes a valid cross-day rule. PA1's next-day learning-off request also passes on attempt 1 through the normal envelope. Recorded evidence: `TestFixtures/live/rf1/reflection.json`, `TestFixtures/live/pa1/pa1-brief.json`; private run: `build/live/20261018T053817.116490Z/`.
- The initial English brief fit in the pane and correctly delivered normally; the probe's pointer assertion rejected it. The final fixture uses six bounded synthetic wide-character focus descriptions to exceed the pane capacity. No production capacity threshold was changed to force this proof. The localhost model scripts tool choices; these probes establish CLI/transport/tool integration, not model reasoning quality.

Initial focused compile attempts caught a mistakenly changed unrelated assertion and a generated-project reference to removed Python bytecode; both were corrected before the passing run. The new recovery test also needed separately awaited actor counters. No production verifier was weakened and no test timeout was increased.

The first full quick run passed every agent probe but exposed an obsolete E2E contract: `longMessageInShortPaneQueuesWithoutCreatingAnUnsubmittedDraft` still expected oversized messages to remain queued. The replacement checks pointer submission, one attempt, no fabricated ack, exact-body fetch and consumption acknowledgment for all three Unicode inputs. The normal full suite skips this opt-in private-tmux scenario. A narrow Xcode selector matched zero tests, so it is not counted as verification; the complete quick gate exercises the replacement. No production code changed after the passing full suite.

Final complete `scripts/live.sh --quick`: **25/25 scenarios PASS**, 337.63 s, including **28/28 E2E tests with zero skips** and the three parameterized oversized Unicode messages. Evidence: `build/live/20261018T060115.029713Z/`, log `build/fx7-quick-final.log`. Tmux hygiene reports no new shared-directory entries or orphan managed fixture servers.

All proof processes exited. Worktree `build/tmp/` was removed before handback; recorded logs and scrubbed fixtures remain.
