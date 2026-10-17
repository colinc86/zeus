# DV1 document delivery and refresh proof

## Platform changes

Template v5 prefers Markdown for documents written for the user, explains that the user reads them inside Zeus, and asks the assistant to update the same attached path and say what changed. Both template files and the new immutable hash-table entry ship together in `cb14cbd`; versions 1–4 and legacy hashes are unchanged. Designer approved the copy. CONTRACT §4 documents this guidance and the unchanged attachment-reference semantics; no MCP schema or runtime API changed.

`dv1` is registered in the live gate, including `--quick`. Its real Claude CLI uses a localhost scripted model, private tmux socket, disposable HOME/config, fixture encryption key and scratch Markdown file. Only that disposable configuration grants native Edit permission. No user files, agent configuration, credentials or default tmux server are used.

## Real-agent evidence

`scripts/live.sh --quick --only dv1 --agents claude` passed with Claude Code **2.1.302**. The gate built the app, then ran the probe in 29.43 seconds (79.03 seconds including the build). Native tool order: `Read`, `zeus_say`, `Edit`, `zeus_say`.

The probe waits until the first card is stored and verifies the original file contents before allowing Edit. It then verifies:

- The same Markdown path contains the new rollback-checkpoint sentence.
- The original card and its attachment remain unchanged.
- The follow-up card describes the change and references the same path.
- Native tool results contain no errors.

Scrubbed proof: `TestFixtures/live/dv1/document.json`. Local gate manifest/logs: `build/live/20261017T030231.503729Z/`; summary: `build/dv1-quick.log`. Probe cleanup and the gate namespace sweep completed successfully.

This is a transport/file-update proof with a scripted model, not a test of the model's independent choice of format or prose.

## Viewer coverage boundary

The platform probe is headless and does **not** claim to render the viewer. Appdev independently reported and supplied passing source/log evidence for:

- `DocumentViewerTests.atomicStablePathRefreshPreservesPageAndScrollBookmark()`: opens `.md`, atomically updates its path, checks refreshed content, retained page/scroll bookmark and `updatedAt`.
- `DocumentNativeViewerTests.atomicReplacementRefreshesVisibleTextAndKeepsScroll()`: opens a private 300-line `.txt` fixture in source mode, atomically replaces it with 400 lines, waits for the production watcher, and checks native NSTextView content, selection and fractional scroll after updating the native renderer.

Appdev's initial gate passed 5 tests in 2 suites (`build/dv1-core-tests.log` in its worktree). These are separate component checks, not one integrated Claude-to-rendered-Markdown test. Appdev is adding rendered-Markdown/source-toggle and panel Back/focus coverage as the viewer lands; that final UI gate remains app-owned.

## Other verification

- Live gate's `scripts/build.sh`: passed; compiler warnings were in unchanged files, with no new warning from DV1 changes.
- Offline gate suite: 11 tests passed, including registration of `dv1` in quick mode.
- `LM4TemplateTests`: all 4 tests passed (`build/dv1-template-tests.log`), including current v5 hashes, complete shipped Git history, preservation of user-edited templates/symlinks and setup-freshness tracking.
- Public check and whitespace check passed.
- Full app suite and full multi-agent live gate were not run for this targeted platform check.
