# LM2-C native gate

All inputs are synthetic. No real typing, real clipboard content, user configuration, keychain or other app was read.

## Observed on 2026-10-14

The owned-editor gate ran with a disposable HOME and stopped immediately:

> LM2-C native gate blocked: Input Monitoring is not granted to this dev build.

`native-gate.json` is the probe's actual output. No tap, window or permission prompt was created. The three-run editor,
paste marker and native secure-field acceptance gate is **not verified**; neither is physical-key capture or live
permission revocation. Recorded layout sequences, injected secure-input/revocation, and the run/storage pipeline are
covered by deterministic tests.

A separate model-only check used the production `LocalRedactor` and `RunRedactor` on two harmless synthetic inputs.
Apple's model triggered its guardrail on each request; the mandatory pass declined and both runs were dropped. An
independent native topic request then failed with Apple's `CriticalMemoryPressure` execution-state response. This is
**not successful native model/topic evidence**. No words, topics or invented success records were kept. Errors are not
fed back into stored content. The production behavior remains fail closed; no relaxation of guardrails was made.

Logs in the platform worktree: `build/lm2c-native.log`, `build/lm2c-real-model.log`, `build/lm2c-model-corpus.log`.
The current fixture saves semantic outcomes before attempting its separate topic request on future runs; the failed
observed run predated that diagnostic-only change. Do not interpret a missing topic artifact as a successful request.

## Reproduce after an explicit permission grant to the exact dev build

```sh
mkdir -p "$PWD/build/lm2c-private-home"
HOME="$PWD/build/lm2c-private-home" CFFIXED_USER_HOME="$PWD/build/lm2c-private-home" \
TEST_RUNNER_HOME="$PWD/build/lm2c-private-home" TEST_RUNNER_CFFIXED_USER_HOME="$PWD/build/lm2c-private-home" \
TEST_RUNNER_ZEUS_LM2C_HOME="$PWD/build/lm2c-private-home" TEST_RUNNER_ZEUS_TEST_LM2C_NATIVE=1 \
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$PWD/build/DerivedData" -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/TypingNativeTests test
```

The fixture checks its inherited HOME, Input Monitoring, model availability and its own frontmost key window. It uses a
**per-process tap** with an explicit marker, rejecting all unmarked keys before reading key content. It never starts a
global tap. It posts synthetic keys only to itself, uses a private named pasteboard (the editor alone reads its planted
token), and never changes the real clipboard or active input-source preference. The active layout must be US or ABC.
It types two normal stretches, with a paste in the second, then focuses an owned `NSSecureTextField`. It verifies real
secure input before posting the third stretch and expects exactly two journal rows. Model refusal drops a run and fails
this acceptance gate rather than weakening redaction. All windows/taps are closed on exit.

For the independent synthetic model/schema check use the same disposable-HOME command with
`TEST_RUNNER_ZEUS_TEST_LM2C_MODEL=1` instead of `TEST_RUNNER_ZEUS_TEST_LM2C_NATIVE=1`. It requires the complete suite filter
shown above; a method filter without Swift Testing's exact method identifier can silently select zero tests.

The ordinary typing suites never install a tap, prompt for permission, change focus, generate native-model requests or read
the screen. Its event source and model are injected fakes. The opt-in harness never requests permission either.
