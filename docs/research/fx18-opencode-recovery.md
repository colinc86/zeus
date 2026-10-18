# FX18 — OpenCode saved-paste recovery

A persisted `tmux_paste_destination` survived Zeus relaunch, but the connector's
original empty-input screenshot did not. The fallback checked only Claude and
Codex composers. OpenCode's exact saved text therefore failed verification and
blocked later messages behind the same pane owner.

## Recovery

OpenCode now has its own exact visible-composer verifier. It obtains the input
width from the box's bottom border, rather than the pane width (OpenCode can show
a sidebar). It checks all input rows, cursor position, wrapped text and explicit
line breaks. It rejects extra text below the caret, human edits, and hidden paste
labels. Fresh paste verification uses the same bounded matcher while retaining
its pre/post footer check.

Recovery is still a continuation of the original delivery: one Enter, no second
paste, no extra attempt. It works with a new runtime and connector, including at
five exhausted attempts. The submission receipt clears the ownership marker;
subsequent messages can then acquire the pane.

An opaque `[Pasted ~N lines]` cannot prove what bytes it contains after relaunch.
It is never automatically submitted based on its line count. Its durable review
state publishes the designer-approved explanation, including for connected
sessions, and remains until the pane is resolved:

> Zeus's saved text is waiting in Terminal
>
> OpenCode is holding text Zeus pasted before the relaunch, and Zeus can't read
> it back. Open Terminal to send it or clear it. Zeus never submits text it can't see.

The existing Open in Terminal menu action is available; this change does not add
a new UI button. Clearing input retires the paste marker without fabricating a
transport receipt. Later messages can flow, while the original undelivered
request retains the normal retry/discard lifecycle.

## Regression evidence

`OpenCodePasteRecoveryTests` uses synthetic 120×40 screens and a process-runner
fake, plus a real durable ledger reloaded into a new runtime. Cases cover exact,
edited and hidden input at attempts 1 and 5, multiline wrapping, one Enter with
zero repastes, subsequent delivery, and clearing hidden text without a receipt.
It also rejects a human-added newline far from the wrap edge and text below the
caret. No fixture touches a real HOME, keychain, agent configuration or tmux server.

`ManagedPaneTests.realOpenCodePasteVerification` retains the recorded native
sidebar and Unicode fixtures. `N1LineBreakTests` still rejects same-line-count
opaque replacement; its expected error is now the actionable hidden-paste error,
not the generic input-changed error. Existing Claude recovery checks remain intact.

Before: an exact persisted OpenCode paste throws `ConnectorError.inputChanged`.
After: the same visible paste submits once, clears its marker and unblocks the
next delivery. Hidden input instead returns `TmuxPasteRecoveryError.hidden` and
publishes the review explanation above.

## Native timer capability

`TestFixtures/live/fx18/timers.json` records Codex **0.163.0** and OpenCode
**1.18.31**, each launched with the production managed controller, its own
throwaway HOME/project, private tmux socket and localhost model. Both resumed the
same native conversation ID and returned a real Zeus tool reply after restart.
The model requests' complete tool catalogs were recorded before and after resume.
Neither CLI exposed a native timer/scheduler tool (no CronCreate equivalent).
Accordingly there is no built-in timer state to create and test for survival in
these tested configurations. This is **not** a claim that arbitrary shell jobs,
OS schedules or user-installed plugins die on restart; those are separate
mechanisms and were not tested. Claude's timer persistence is outside this check;
we do not infer it from conversation or process lifetime.

Reproduction: `python3 -B docs/research/fx18-timers.py`, after building in an isolated
worktree with the heavy slot. The copied diagnostic host adds only a restart
command. Its Codex localhost-model overrides stay **before** the `resume`
subcommand, alongside the production overrides. Putting the model flags after
`resume` in an initial diagnostic attempt shadowed the earlier MCP configuration;
correcting that fixture restored the bridge. No production launch change was
needed. The private pane receives a literal continuation after resume to provoke
a new model request, then a Zeus-delivered message and actual `zeus_say` reply.

## Gates

- Focused: 23 tests / four suites passed, including the recorded OpenCode sidebar
  and Unicode cases, hidden-paste safety and the new reloaded-ledger cases.
- Full `scripts/live.sh --quick`: 26/26 jobs passed in 647.22 seconds; includes
  28 private-tmux end-to-end scenarios. Hygiene found no new shared-directory
  entries or orphan managed fixture servers.
- `scripts/check-public.sh`: passed.
- Final `scripts/test.sh`: 1,242 app tests / 252 suites passed in 463.406 seconds
  (1,204 passed, 38 expected opt-in skips), plus 276 package tests and offline gates.
  The final full run includes all fixes and updated expectations.
- The build inside the live gate passed without new compiler warnings.

All build products were routed to `build/tmp/fx18/` using temporary build aliases.
Only scrubbed proof is retained; task build products and aliases are removed
before hand-back.
