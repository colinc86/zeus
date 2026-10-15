# Phase D private Claude proof — 2026-10-15

Real Claude Code **2.1.300**, actual bundled `zeus-mcp`, production ZeusRuntime/TmuxConnector,
encrypted journal/rules stores with a fixed fixture key. Private tmux socket, disposable HOME/config,
scratch project, localhost synthetic model. No user agent settings, credentials, Keychain, windows or
default tmux server were accessed. Fixture ciphertext opts out of OS file protection; production does not.

Command: `python3 -B Zeus/App/Tests/Runtime/PhaseDLiveProbe.py`

Final result: **PASS**. Actual tool sequence:

1. `zeus_get_journal`: synthetic focus summaries returned; native Claude sent the tool result back to
   the localhost model. The exact answer text appears once in the sent ledger.
2. `zeus_propose_rules`: cites two synthetic journal IDs from different days. Passive rule active;
   spend rule shadow.
3. `zeus_ack`, `zeus_say`: reflection consumed on attempt 1.
4. `zeus_rule_shadow`: spend action asks about **14 EUR**; no purchase approval is supplied and the
   rule stays shadow.
5. `zeus_rule_acted`, `zeus_say`: approved passive action reported with a reversible instruction.
6. Host invokes the runtime's actual notice Undo closure. It records one undone outcome and delivers
   the Undo instruction to the original session.
7. Real Claude consumes that instruction and calls `zeus_ack` / `zeus_say`. Undo acknowledged on
   **attempt 1**, with no manual Enter or delivery bypass.

`proof.json` contains scrubbed state, actual notices/outcomes/receipts, tool names and final private
pane. It contains only synthetic data. Processes and the private socket were removed by fixture cleanup.

## Failure reproduced and fixed during the stronger Undo check

Before the final fix, the exact journaled Undo paragraph remained in the composer. Captured evidence:
`undo-wrap-boundary.json`. Claude wrapped `wording` onto the next row even though space + word exactly
fit the remaining columns. The verifier accepted only a strictly larger next word, so it rejected the
correct paste. The fix accepts equality while still matching every paragraph byte and the full delivery
ID. `PhaseDUndoPasteTests` replays this capture and rejects extra or replaced text. The final CLI run
above proves actual submission and acknowledgement after that change.

## Other gates

- Final focused core run: **72 tests / 10 suites pass**. Includes encrypted stores/recovery,
  Phase D tools/outcomes/reflection, connector/suggestion regressions and real synthetic OCR.
- Package suites: **247 tests pass** (native opt-in/locked-console skips remain explicit).
- Build: no new warnings. Public check passes.
- Full `scripts/test.sh`: **not green**. Protected-write failures were resolved with explicit fixture
  keys/storage policy. Subsequent ordinary full app runs on both worktrees hit managed deadline
  cascades and AppKit animation workers saturated the 64 dispatch-thread limit. Appdev reproduced
  without render opt-in or overlapping probes. This remains a separate full-suite gate blocker.
