# FX13 — preserve useful typing topics

## Evidence and cause

All inputs here are synthetic. No user journal, typed words, assistant folder, input tap, credentials or keychain was read.

The previous check joined subject and recipients into one unsafe predicate. Any unknown role, digit, privacy marker or detected private detail in either field replaced the subject with intent + app and removed all recipients. Fake-model fixtures reproduce each rejection path. The existing test explicitly expected an unknown recipient to discard a safe “Project update”; that obsolete expectation now checks independent validation.

A real on-device model run on three synthetic prompts (guitar arrangement, riff refinement and code review) returned:

| Native model subject | Recipient | Old check | New check |
|---|---|---|---|
| Guitar arrangement with contrasting riffs | assistant | Intent fallback: unknown recipient | Preserved |
| Tightening melodic response between guitar parts | assistant | Intent fallback: unknown recipient | Preserved |
| cancellation race risks and test design | assistant | Intent fallback: unknown recipient | Preserved |

The old check would reject assistant regardless of the chosen intent. This verifies the mechanism, not the frequency of each cause in historical user data.

## Changes

- Independently validate the whole subject and normalize recipient roles. Unknown/unsafe recipients are dropped without changing a safe subject. Supported agent roles: AI assistant, coding agent, assistant, bot; leading a/an/the and case differences are accepted.
- Strip complete privacy placeholders before judging the remaining subject. Incomplete markers still fail closed.
- Preserve safe recipients even if the subject needs a fallback.
- Reject subjects that merely repeat intent and app, and instruct the model to describe subject matter.
- Keep **all digits prohibited**, including version tokens. A short topic cannot reliably distinguish a software version from personal numeric information.
- Validate before the eight-word bound, so a private suffix cannot escape checking.
- Export identical description/topic text once rather than twice.
- Typed-run stage-two redaction, capture permission/scope checks, encrypted storage and retention are unchanged.

Synthetic before/after:

| Input subject; recipients | Old | New |
|---|---|---|
| Guitar arrangement feedback; an AI assistant | Drafting in Warp | Guitar arrangement feedback; ai assistant |
| Song riff refinement; coding agent | Drafting in Warp | Song riff refinement; coding agent |
| Code review; agent 42 | Drafting in Warp | Code review; no recipient |
| ‹name› Guitar arrangement feedback ‹secret›; manager | Drafting in Warp | Guitar arrangement feedback; manager |
| Project update; priya | Replying in Fixture | Project update; no recipient |
| Email john@example.test; manager | Drafting in Warp | Drafting in Warp; manager |
| Meet John Smith; manager | Drafting in Warp | Drafting in Warp; manager |
| Version 42 review; manager | Drafting in Warp | Drafting in Warp; manager |
| ‹name›; manager | Drafting in Warp | Drafting in Warp; manager |

Check diagnostics expose only a typed rejection category and dropped-recipient count; they do not log private input. The opt-in native model test is separate from deterministic regressions and does not assert exact generated wording.

## Verification

- Build-for-testing passed with no new warnings.
- Focused typing checks: 27 tests / 2 suites passed, including the real on-device synthetic probe (three useful subjects, all preserved).
- Full scripts/test.sh: 1,216 app tests / 246 suites; 1,179 passed, 37 expected opt-in skips, zero failures (553.524 s). All 274 package tests and offline fixtures passed. No new fixture tmux leaks.
- Public-content check passed.
- Complete scripts/live.sh --quick passed (538.60 s), including all real-agent probes and E2E. Tmux hygiene clean. All temporary task build output was removed after verification.
