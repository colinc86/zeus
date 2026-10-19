# Journal partitions and civil-time schedules

The journal's physical day filename is the calendar at the time of insertion. After a time-zone change, it is not necessarily the current local day of the records inside it. Mutations must locate existing records by physical partition, not reconstruct a filename from their timestamps.

Typing and frame/description deletion now find those partitions. Undo receipts remember their original filenames. Multi-file replacements use an encrypted `pending.ztransaction` containing the complete replacement arrays, written atomically before checkpointing the day files. This is the commit point. Interrupted checkpoints replay before any subsequent read or mutation; a failed replay exposes no partial snapshot. Single-file replacements retain their existing atomic encrypted write. Deletion observers run only after commit. Delete Everything removes the transaction first, so an interrupted restore cannot repopulate an erased journal, and still does not need the encryption key.

## Mutation audit

- New append: derives a day path only for a genuinely new ID; the global ID check remains authoritative. No existing record is relocated.
- Typing group delete and Undo: physical partitions, now permits cross-partition selections. Missing/conflicting selections still fail before mutation. Existing expiration/forget-epoch checks remain.
- Picture deletion (with or without description) and Undo: physical partitions, including a pair originally written under different zones. Image ciphertext is written before restored metadata; deletion unlinks it after metadata commit. Orphan cleanup remains safe.
- Generic item/day/app deletion: already iterates physical files. Frame item deletion delegates to the corrected paired operation. Day matching uses the selected local calendar, independently of the physical filename.
- Retention, screen retention, typing preference shortening and timed word expiration: already rewrite the physical URL being iterated. No path reconstruction change needed.
- Delete Everything: also removes the transaction marker without decrypting it.
- Level-off/app-policy erasure and outbound-policy rebuild: use the above journal deletion/query APIs or create new records; no additional existing-row filename reconstruction found in the journal mutation paths.
- Folder enumeration is a read-only physical-day export API, not a mutation or migration. This task does not redefine its grouping.

No storage migration is performed. A stable UTC partition convention is worth considering if simplifying indexing/export is a future goal, but filenames are authenticated encryption identities, so migration must decrypt/re-encrypt and handle interruption. It is not needed for correct deletion and would not eliminate the need for multi-partition group transactions. Keep physical partition identity separate from local-day presentation either way.

The morning brief computes tomorrow's configured hour/minute on tomorrow's civil date. It no longer adds a day to today's DST-normalized time. A skipped 02:30 is 03:00 on spring-forward Sunday, then returns to 02:30 on Monday. The first occurrence of repeated fall-back time is used; the durable brief-day guard still prevents a second brief that day.

## Regression coverage

`JournalZoneTests`: changed-zone deletion/Undo, mixed-zone physical partitions, paired picture/description deletion and Undo, injected-key interruptions before and after the multi-file commit, keyless Delete Everything over a pending transaction, and retention/app erasure after travel. All keys and contents are synthetic.

`PA1ProactiveTests`: configured-time boundaries on ordinary, spring-forward and fall-back days, including between the repeated hour's occurrences; once-per-day brief delivery.

The existing cross-day rejection assertion in `TypingLearningTests` is replaced with successful atomic deletion/Undo because cross-partition selection is now supported; missing-ID, expiry, conflict and forget-epoch assertions remain.

Verification results are recorded in the task hand-back.

## Final verification

Rebased onto main `deae20c`; verified code tip `326c2d0`. All gates ran from an isolated checkout under `build/tmp/fx23/`, with fixture keys, private sockets and disposable agent profiles only.

- Focused `JournalZoneTests`, `TypingLearningTests`, `PA1ProactiveTests`: **38 tests / 3 suites PASS**, 1.515 s on the rebased tree.
- `scripts/test.sh`: **1,292 app tests / 263 suites PASS**, 572.536 s (1,253 passed, 39 expected opt-in skips); **277 package tests** plus offline checks passed. No failures or test-host crashes. Tmux hygiene clean.
- `scripts/build.sh`: PASS; no new compiler warnings. Existing destination-selection warning unchanged.
- `scripts/check-public.sh`: PASS.
- Complete `scripts/live.sh --quick`: **26/26 PASS**, 615.87 s, including reflection, morning brief, rule trigger, all three real agents and private-tmux E2E. Run identifier `20261019T003939.018461Z`; tmux hygiene clean.
- `git diff --check`: PASS. Scratch checkout, generated binaries and logs removed with `build/tmp` before hand-back.

Before/after: the Chicago Nov 1 record viewed after switching to Los Angeles previously survived Delete in its Nov 1 file; now the original physical record is removed, and Undo restores it to that file even when the group also contains an Oct 31 partition. A configured 02:30 brief previously scheduled Monday after spring-forward at 03:00; it now schedules Monday at 02:30. No storage migration or tool schema change.
