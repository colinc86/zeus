# LF1 assistant-folder record

The shared `LearningFolderWriter` reads retained, already-redacted journal records, covered frames, redacted summaries and rules. It never reads capture sources. Runtime owns its start/stop and applied managed-folder identity; app composition supplies the same instance to Privacy and the enabled-level closure. Connect-your-own selection lives in the injected private manifest.

The export uses one journal day at a time, one decoded picture at a time and batches of at most 20 text files. Epoch checks and a disk lock serialize erasure against background writes. Temporary files are mode 0600 and renamed atomically; export directories are 0700. A corrupt manifest is surfaced without overwriting it. Symlinks below the selected root are rejected. Existing exports in a previous destination are left alone.

Journal deletion and retention remove exported content, while Undo can restore it. Finder deletions have separate durable tombstones, including a deletion immediately followed by a disabled-level prune. Delete Everything clears `Zeus/`; only an explicit `includeAssistantNotes` clears `Notes/`. Neither operation edits the assistant templates or other files.

Digest and moment deliveries append existing relative file paths. Reflections write their full delivery body, including the final `Files:` line, before sending. Tool-result and ack receipts retain the exact delivered body. The real-Claude LM4 live probe now requires a native `Read` of the referenced digest file before `zeus_ack`, verifies the returned file content in the localhost model transcript, and retains its late-ack-after-erasure check.

`coverPictures` defaults on. Off omits optional text/picture/face coverage, but mandatory secret/card/IBAN/identity regions remain covered. Capture hard stops and textual redaction are unchanged. The unchanged-frame cache includes this policy bit, so turning coverage on cannot reuse an old uncovered preview. Stored frames are never un-covered.

## Verification

- `build/lf1-checkpoint-build.log`: build passed, no new warnings.
- `build/lf1-focused3.log`: 23 folder, Phase D and template tests passed; includes generated-image OCR/re-OCR, password-dialog rejection, exact reflection receipt and template-v2 hashes/history.
- `build/lf1-folder-final.log`: expanded 10-test folder suite passed, including retained JPEG/description layout and independent words expiry.
- `build/lf1-tombstone.log`: 10 folder tests passed after adding the Finder-delete/disable boundary.
- `build/lf1-real-claude.log` and `TestFixtures/live/lm4/digest.json`: real Claude Code 2.1.301 passed native `Read` → `zeus_ack` → `zeus_say`, one delivery attempt, exact file-line receipt, and no late-ack ledger after erasure.
- `build/lf1-live-quick.log` / `build/live/20261016T014652.605222Z`: default `scripts/live.sh --quick` passed every probe/agent including E2E in 436.01 s.
- Final writer follow-up `28a5ee8`: observable Finder availability, reuse of immutable frame exports (delete/Undo invalidates the cache), and omission of stale file references after an export error. `build/lf1-final-writer.log`: 13/13 tests passed in 3.051 s. `build/lf1-final-real-claude.log`: real-Claude file-read proof passed again against this follow-up.
- Integrated build and 14 final app/layout tests passed. The first full run failed two obsolete app disclosure-prefix expectations; appdev corrected those while retaining geometry checks.
- The final quiet integrated `scripts/test.sh` **failed**: 1,068 tests, 1,037 passed, 28 skipped, three failures in 422.360 s. Evidence in the appdev worktree: `build/lf1-full-test-quiet.log` and `build/lf1-quiet-summary.json`. Failures: `ConversationFirstClickTests.choiceRespondsToOneHeldPress` (`focusCameFromPointer` false), `LM2DNativeTests.sentThumbnailOpensItsStoredPictureInADetailSheet` (`attachedSheet` nil), and the Claude argument of `ManagedTmuxIntegrationTests.ownedLifecycleResumeAndCollisionUseOnlyPrivateSocket` (restart phase still starting/busy at its deadline). LF1 tests passed; packages/offline gates passed.
- A preceding quiet narrow run of ConversationFirstClickTests and ManagedTmuxIntegrationTests passed all five tests/two suites, including all three managed agents, unchanged in 110.105 s. The subsequent quiet full failure means external render overlap is not a sufficient explanation. No assertions, deadlines or production behavior were changed to hide the failures. The managed controller and lifecycle fixture are unchanged from the LF1 base; that fixture constructs a controller directly, without the folder writer. This narrows the investigation but does not establish a root cause or rule out suite interactions.
- **Full-gate status: blocked.** LF1 implementation and live proof are complete; the three full-suite failures remain unresolved.

All storage tests inject fixture encryption keys and temporary destinations. Live checks use a private tmux socket, disposable HOME/config and a synthetic localhost model; they never use the user's assistant folder or credentials.
