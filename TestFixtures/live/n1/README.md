# N1: multiline owned paste

Recorded with Claude Code 2.1.296, Codex 0.162.1, OpenCode 1.18.31 and tmux 3.6a in a 120 × 40 private terminal. Each CLI runs in a disposable HOME and scratch project against a localhost model fixture, with synthetic credentials. No real user configuration, credentials, tmux server or inference is used. `/FIXTURE` replaces the scratch root.

`*-before.ansi/.meta` records the empty composer immediately before delivery; the matching `.ansi/.meta` records the complete live composer immediately before Zeus sends Enter. `before.*` records initial readiness. Metadata is `cursor_x|cursor_y|pane_width|pane_dead|cursor_flag|bracket_paste_flag`; tmux 3.6a does not expose the final field, so it is empty. The known composers are verified against these real renderings; an explicit mode-off flag or unfamiliar terminal refuses multiline injection.

The fixture sends three lines, eight lines, an internal blank line plus a quoted prompt/header, and three long wrapped lines. OpenCode's eight-line case uses shorter lines to fit its capped textarea. The larger wrapped eight-line case is refused before paste (unit regression). Managed OpenCode's existing `disable_paste_summary` setting is reproduced. `opencode-summary/` records the same cases with summaries enabled, as a connected external session may use them.

The production connector loads one named buffer over stdin, pastes with `-p -r`, verifies, then sends one Enter. The real CLI's outbound model request must contain the exact normalized envelope, including every LF and internal space. OpenCode with summaries adds one editor separator space after the envelope; that precise suffix is included in its live assertion. The test checks four messages and exactly four Enters per agent. The model only replies “Ready.”; tool acknowledgments are outside this transport check.

Claude can render `[Pasted text #N +M lines]`, Codex `[Pasted Content N chars]`, and OpenCode `[Pasted ~N lines]`. A size-only label cannot prove the hidden bytes or a durable delivery ID. Zeus accepts it only immediately after its own fresh, journaled paste into a verified empty composer. An interrupted paste is never recovered from the label alone: it remains queued for review in Terminal, rather than risking submission of a replacement human draft of the same size. Visible full-envelope recovery retains the existing exact-match guard. One exception is Claude's numbered label. Once Zeus has verified its fresh paste, it journals the exact label (`#N` and line count) before Enter. Claude never reuses a number within a process, so that exact label alone may be recovered if Enter does not take. A different number never matches (CONTRACT §5.4).

Re-record from the worktree root:

```sh
xcodegen generate --quiet
TEST_RUNNER_ZEUS_N1_LIVE=1 TEST_RUNNER_ZEUS_N1_RECORD_FIXTURES=1 \
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/N1LiveDeliveryTests test
```

Remove `TEST_RUNNER_ZEUS_N1_RECORD_FIXTURES` to verify without rewriting captures. `TEST_RUNNER_` is required to pass opt-in flags into the Xcode test host. Ordinary `scripts/test.sh` runs the offline fixtures and skips real CLI launch.

The default OpenCode height cap is documented in its [1.18.31 prompt source](https://github.com/anomalyco/opencode/blob/v1.18.31/packages/tui/src/component/prompt/index.tsx). Unknown/smaller custom layouts must still pass the full post-paste comparison before Enter.
