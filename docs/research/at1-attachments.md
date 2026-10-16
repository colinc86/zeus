# AT1 attachment synopsis verification

2026-10-16, platform/at1-attachment-summary.

`Attachment.summary` is optional for persisted/legacy cards. New MCP file/folder attachments require at least 20 non-whitespace characters and at most 400 total characters; URL summaries remain optional, with the same upper bound when supplied. Invalid attachments reject the entire say/present call before adding any card. The schema, agent instructions and CONTRACT describe these rules. `zeus_update_card` does not accept attachment edits; text updates preserve existing summaries, and unsupported attachment edits still fail.

Designer template v4 and its hash-table entry were adopted together from `f7d0f4e` as `0cd2541`. No designer chip implementation was included in that cherry-pick.

## Verification

- `scripts/build.sh`: passed; no new compiler warnings (`build/at1-build.log`).
- Full ZeusKit `swift test --package-path Packages/ZeusKit --scratch-path build/ZeusKit`: passed, 254 tests across product suites, including expected opt-in skips (`build/at1-package.log`).
- AttachmentSummaryTests, RuntimeToolTests and AgentUXTests: passed, 23 tests (`build/at1-targeted.log`). Coverage includes legacy decoding, round-trip storage, missing/short/whitespace/wrong-type/overlong summaries, Unicode boundaries, whole-call rejection, URL compatibility and update preservation.
- `ZeusE2ETests/presentationScenario()` plus LM4TemplateTests: passed, 5 tests (`build/at1-e2e-template.log`). The real-process presentation fixture carries a valid summary. Template tests verify v4 bytes and all shipped historical versions.
- Searched package/app tests and fixture source for attachment field and tool-argument lists. Updated WireTests' nested schema expectations, existing runtime file-attachment calls and appdev's isolated E2E fixture change. Top-level tool argument lists are unchanged. Historical recordings and legacy direct model constructors remain compatible.
- `python3 -B scripts/test_live_gate.py`: 10 tests passed. `scripts/check-public.sh` and `git diff --check`: passed.

## Real Claude proof

`python3 -B Zeus/App/Tests/Runtime/AT1LiveProbe.py --record` passed with Claude Code 2.1.301. The real CLI uses a localhost scripted model, private tmux socket, disposable HOME/config, scratch document and fixture encryption key. It first calls `zeus_say` with a file and no summary, receives the exact guidance with `is_error: true`, then retries with a summary. Production runtime storage contains exactly one card and its exact summary. This verifies transport/validation/retry behavior, not the model's independent judgment of synopsis quality.

Scrubbed evidence: `TestFixtures/live/at1/attachment.json`. Local logs: `build/at1-live/` and `build/at1-live.log`. Probe-owned processes and scratch namespace were cleaned up. The probe is registered as `at1` in the live gate.

The heavy slot was released to appdev after these checks. The full app suite and full live gate remain PM-owned merge gates per the task; neither was run here.
