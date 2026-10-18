# FX7: long delivery pointers

Implementation and verification in progress on `platform/fx7-long-deliveries`.

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

## Verification so far

- `swift test --package-path Packages/ZeusKit --scratch-path build/ZeusKit`: 274 package tests pass (`build/fx7-package-final.log`). Schema argument-list expectations were updated and the remaining tests searched for old lists.
- Focused app gate: 31 tests / 4 suites pass in 13.351 s (`build/fx7-focused-final.log`). Covers an 80×24 pointer, exact recipient-scoped fetch, full-body receipt without fabricated ack, size-only startup retry, expired requests and late acks, interrupted pointer recovery without repasting, existing multiline/draft guards, all three managed fixture lifecycles and parent-exit cleanup.
- Five tmux hygiene tests, 14 offline live-gate tests, public check and `git diff --check` pass.
- The RF1 probe now uses the actual 120×40 default and fetches the pointer before native Notes/rule work. PA1 brief seeds six bounded synthetic focus summaries; its next-day check still covers learning off. Real probe execution and full gates remain pending the PM's heavy-slot grant.

Initial focused compile attempts caught a mistakenly changed unrelated assertion and a generated-project reference to removed Python bytecode; both were corrected before the passing run. The new recovery test also needed separately awaited actor counters. No production verifier was weakened and no test timeout was increased.
