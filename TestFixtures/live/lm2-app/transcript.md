# LM2-A native app evidence

All input is synthetic. No user's agent configuration, credentials, tmux server, existing editor window or browser content
was read. Tests use disposable HOME/CFFIXED_USER_HOME, private UserDefaults suites and an injected fixture encryption key.

## Native capture

Run `python3 -B Zeus/App/Tests/LM2AppLiveProbe.py` from the worktree root. The helper builds a native dev app from the production
FocusObserver, MacFocusCaptureSource, LocalRedactor and EncryptedJournalStore. It preflights Accessibility without requesting
permission, and refuses any PID it did not launch. The owned editor exposes a real AX window title and AXDocument URL.

The recorded run had Accessibility permission. The owned editor's title contained the synthetic email
`synthetic@example.invalid`; its AXDocument pointed into the disposable HOME. The production pipeline stored one encrypted
record with the email replaced by `‹email›`. The reported engine was `naturalLanguage` (the mandatory local fallback), not a
claimed successful Foundation Models pass. `proof.json` contains only assertions/counts, not captured text or private paths.

The specific real-Xcode gate remains incomplete: a new instance was requested through NSWorkspace with
createsNewApplicationInstance and the disposable HOME, but that process exited while the user's pre-existing Xcode was
running. The helper refused to follow it into the existing instance. It never read that instance's windows or documents.
The owned editor proves the AXDocument and redaction path; it is explicitly not a claim that the Xcode gate passed.

The Safari title/URL native gate was not run: this environment has no verified disposable Safari profile, and a test must
not access the user's browser/history. Phase A defaults Safari to app-only; per PM's amendment an explicit Level 2 allow-list
selection permits its titles/addresses, with the warning that private windows are included. The allow-list/default/private-list
rules are covered by tests, and the warning was reviewed in native renders. Safari/Automation still needs the scoped real-app
acceptance check. Chrome/Edge use the normal/incognito mode guard, with an additional Incognito title stop.

## Views

Run the `LM2RenderTests` app suite with `TEST_RUNNER_LM2_RENDER=1`. It renders synthetic Privacy, consent, journal, sent-ledger
and Rules surfaces through NSHostingView.cacheDisplay at 1× and 2×, in light and dark. No Computer Use or screen capture.
The designer approved the final Safari warning, ledger disclosure/session dot, rule controls and copy.

## Logic and integration

Focused coverage includes independent scope coins and the shared private list; no AX reads before opt-in/permission or while
secure/locked/private; app-switch/disable/delete boundaries during asynchronous redaction; record deduplication; failures and
retry; exact stored filtering/export; immediate delete and bounded Undo; rule identity/evidence preservation; quiet durable
notice/action reconnection; conditional Rules tab; last-input context before the ten-minute reflection deadline; and retention.
Drops exercise files, folders, URLs, text and image-file creation, removable chips, and durable queued/failed message handling.
The folder action uses the existing managed S3 confirmation, which is automatically scrolled into view.

The final build/test/public gate results are recorded in the task handback and worktree build/lm2-*.log.
