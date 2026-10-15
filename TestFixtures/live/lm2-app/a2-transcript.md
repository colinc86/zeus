# LM2-A2 integration and native acceptance

## Merge

Merged main into appdev/lm2-app in `6cbc766` after platform LM2-P was merged. Platform-owned Learn/runtime files,
Runtime tests, live/lm2 and lm2-core.md match main. Main's Privacy spec and design harness already include the complete
Phase A material plus the later Phase B/C additions, so that union is preserved. App-owned implementation is retained.

`21b4d18` restores only LearnSettings.permitsApp, its isExcluded check and the fresh-install 90-day default, with platform
owner approval. This hook is necessary for the app's L1 scope coin; previously saved retention choices remain unchanged.
A regression covers chosen-app scope, private-list precedence and persisted retention.

## Verification

- `scripts/build.sh`: passed; only pre-existing warnings (Sendable button actions, unused ManagedTerminal error,
  and ambiguous destination).
- `scripts/test.sh`: passed, 858 app tests total, 242 package tests, 16 release/appcast and 10 live-gate fixture tests.
- Native fixture compiled with `LM2_PROBE_HOST` and the production capture/redactor/encrypted-journal sources.
- The two Python fixture scripts parse successfully without writing bytecode.
- Fixture-only build and public-check results are in the task handback.

Logs stay under `build/lm2-a2-*.log`. The native run happened after the merged full test gate passed.

## Native result: blocked, not passed

`a2-proof.json` records the real run, with only categories, counts and error codes retained.

**Safari:** Accessibility was available. The dev fixture called
`AEDeterminePermissionToAutomateTarget(..., false)` for Safari and received `errAEEventWouldRequireUserConsent` (-1744).
No consent prompt was shown and no Safari content was read. Safari Automation permission is required by the production
AppleScript URL/title path. No normal Safari window, profile, history or setting was inspected or changed.

The intended disposable browsing context is Safari's native WebDriver automation session. Apple documents those windows
as isolated from normal browsing windows, user settings, history and AutoFill:
[WebDriver: Isolated Automation Windows](https://developer.apple.com/documentation/safari-developer-tools/webdriver).
The session/capture was not started after the failed permission preflight. This is not a Safari title/URL pass.

**Xcode:** A new executable process was launched directly with a disposable HOME/CFFIXED_USER_HOME and synthetic document.
Its open-document event addressed that exact new PID, rather than a bundle-wide existing-instance lookup. It exited before
AXDocument/title capture; no journal item was recorded. The original Xcode process remained running.

Diagnostics limited to the owned process showed developer-account startup failing with no default keychain (-25307),
then a DVTDeveloperAccount.m:253 assertion. Xcode reached account preferences supplied by system services despite the
HOME override. No real keychain was supplied, no credentials were retrieved, and no account settings were changed.
Raw account metadata is not retained in these fixtures. A disposable HOME alone is therefore insufficient for this gate.

The probe now refuses Xcode launches unless explicitly run with `--xcode-clean-user` from a clean macOS test user or VM.
It terminates only processes it launched; it never quits the user's existing Xcode or Safari. The helper reports a blocked
acceptance gate as a nonzero exit. The earlier owned-editor AXDocument/email-redaction proof remains valid pipeline
evidence, but does not substitute for either required real-app check.

## Remaining gate before Phase A ships

Provide a clean macOS test user/VM with Accessibility and Safari Automation permission granted to the dev fixture; then
finish the isolated Safari WebDriver title/URL capture and fresh-Xcode AXDocument/email-redaction checks. No real agent
configuration, credentials, keychain or existing browser/editor contents may be used to make the checks pass.

## Guarded probe verification

On `067ffd9`, `scripts/build.sh --for-testing` and `scripts/check-public.sh` passed. The guarded probe returned exit 1
with an explicit blocked result, did not launch Xcode, and again recorded Safari preflight -1744 without a prompt.
`a2-preflight.json` preserves that check separately from the earlier actual fresh-Xcode attempt in `a2-proof.json`.
The original Xcode and Safari processes remained running; no fixture process was left running.
