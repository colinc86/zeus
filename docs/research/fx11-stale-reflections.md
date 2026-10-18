# Quiet reflection supersession on upgrade

The pre-pattern reflection ID is `d_reflection_<YYYYMMDD>`, the same day-based
ID used by the pattern digest. The old request also counts toward the existing
one-reflection-created-per-local-day guard. Merely expiring some old requests
therefore both creates needless notices and leaves retained requests capable of
blocking replacement.

The runtime now reconciles before delivery selection and after creating a new
reflection. For each reflection or brief, a newer request of the same kind
supersedes an older pending request. The superseded tombstone preserves its ID,
records `discard_reason = superseded`, cancels in-flight work, and emits no notice.
An already pasted native message is left alone; its late receipt has no effect.

Pending pre-pattern reflections are recognized by the shipped legacy request
header plus absent `source_hash` metadata. They are quietly superseded before
startup catch-up. A tombstoned old day ID gets a distinct `_patterns` replacement
ID, so old acknowledgments cannot acknowledge the new body. Superseded requests
do not count toward the same-day guard or the previous-reflection outcome cutoff.

Only the newest request without a successor expires. Expiry notices are emitted
on that durable transition, not replayed from historical discarded records.
Dismissing a notice survives subsequent checks and relaunch.

## Synthetic upgrade evidence

No user ledger was read. The test uses only the supplied UTC timestamps and
lengths, generated placeholder bodies, a scratch ledger, an injected journal key,
a fake clock in America/Chicago, and the production tmux connector with a simulated
80×24 composer. No real tmux process is needed for this regression.

Before: four raw-event reflections for October 14–17, exhausted at five attempts,
held for terminal size. On October 18 the previous implementation would expire
two with Not sent notices and leave two old-format requests eligible for delivery.

After: all four have quiet superseded tombstones. Exactly one October 17 pattern
reflection is created, submitted once as a pointer, fetched with its exact durable
body, and acknowledged. No old-format request reaches the connector and no obsolete
Not sent notice appears. The ordinary new reflection's Sent receipt is unchanged.
Both compact and dashed historical IDs are tested. Separate tests cover a legacy
request created today, creation-time brief supersession, in-flight cancellation,
late acknowledgments, and dismissed expiry notices across restart.

## Verification

- Build-for-testing passed; no new source warnings.
- Focused runtime checks: 25 tests in 4 suites passed.
- Public-content check passed.
- Full `scripts/test.sh`: 1,202 app tests in 244 suites passed (523.275 s),
  274 package tests and offline checks passed; tmux hygiene clean.
- Full `scripts/live.sh --quick`: 25/25 probes passed, no skips (533.33 s);
  includes 28/28 E2E tests. Tmux hygiene clean, no fixture servers left.

Build products were confined to `build/tmp/fx11/`. The entire `build/tmp/` and
its build aliases were deleted after verification. Small logs and summaries remain
under `build/fx11-*`.
