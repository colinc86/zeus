# FX15: managed restart notices

Native agent timers belong to a process. Resuming a conversation restores its history,
not those timers. Zeus now queues a system `restart` delivery after the newly launched
process's owned bridge checks in. Normal managed readiness, draft and permission gates
still apply before input is sent.

Example:

> Zeus restarted you at 11:42 because you pressed Restart Assistant. Timers and scheduled checks you set before the restart are gone. Check what you had planned and set it again. Then zeus_ack.

The reason changes for app update, crash recovery, settings changes and setup/tool
updates. Template v8 and the default launch instructions explain the same limitation.
The thread uses “Restart notice ready for your assistant” and “Sent the restart notice”,
with the exact body available through View. Designer-approved vocabulary is in PRIVACY.

## Durability and scope

- A launch intent contains a stable notice ID before process creation. Successful
  launch, including recovery of an interrupted launch command, commits it to the
  controller's durable outbox. Failed launches do not commit an event.
- The outbox transfers to the delivery ledger only after the current owned pane's
  process identity has been confirmed. Insertion is idempotent; only then is the
  outbox entry removed. Adopting a live pane creates no new event.
- Fresh conversations produce no notice. Two resumed launches produce two IDs.
  Pending notices can follow another process of the same native conversation;
  they cannot be routed to an unrelated assistant or a new conversation.
- Notices work with learning disabled and consume no unprompted-message budget.
  Receipt text is retained through the ordinary delivery-receipt path.
  Delete Everything clears queued notices and prevents erased receipts replaying.
- This is a notice, not a scheduler. Zeus does not recreate native timers or prove
  that an assistant acted on the request. No `zeus_schedule` tool was added.

## Evidence

`TestFixtures/live/fx15/restart.json` records real Claude Code 2.1.302, a localhost
scripted model, disposable HOME/project, private tmux socket and fixture encryption
key. The production controller launches a fresh native conversation, then restarts
it twice. Both resumes keep the native conversation ID. The model receives and
acknowledges two distinct notices, each at attempt 1; both exact-text journal receipts
are present. Fresh launch has no notice and the budget stays at six.

`ManagedRestartNoticeTests` covers fresh/resume, repeated check-ins, runtime relaunch,
two disconnected quick restarts, crash reason, durable outbox reload and erasure.
The existing settings in-flight delivery test still requires both original user
message IDs; it now also requires exactly one settings-restart notice.

Verification on the final production tree:

- `scripts/test.sh`: 1,240 app tests / 251 suites, 1,202 passed, 38 expected
  opt-in skips, zero failures; 614.517 seconds. All 276 package tests passed,
  with the existing opt-in skips; offline hygiene/release/live-gate checks passed.
- Recorded FX15 real-Claude probe: PASS, 43.29 seconds.
- `scripts/live.sh --quick`: all 26 scenarios passed, zero skips; 589.15 seconds.
  Includes the new restart probe and the 28-test private-tmux end-to-end suite.
- `scripts/build.sh`: passed via the live gate, no new compiler warnings.
- `scripts/check-public.sh`: passed; repeated after the final evidence commit.


Build output was confined to `build/tmp/fx15/` through the standard build-path aliases.
The temporary build tree and aliases were removed after verification; fixture process
hygiene reported no new shared sockets or orphan test servers.
