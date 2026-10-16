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
- Final integrated full-suite and real-agent gate results follow in the hand-back/evidence update.

All storage tests inject fixture encryption keys and temporary destinations. Live checks use a private tmux socket, disposable HOME/config and a synthetic localhost model; they never use the user's assistant folder or credentials.
