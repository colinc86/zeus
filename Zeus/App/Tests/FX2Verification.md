# FX2 held-press verification

## Reproduced cause

The initial first-mouse hypothesis was not the cause. The explicit hosting override and CONTRACT §10 sentence remain as requested.

The addendum's first candidate **reproduces in the actual native ConversationHostingView**, using a private CardStore and a 51-card thread. The open question is at the viewport top, with history on both sides. A mouse-down is followed by a run-loop timer's mouse-up 120 ms later at the same point; the test samples focus, viewport and the option's accessibility frame at 80 ms.

Before the focus-scroll fix (`build/fx2-delayed-baseline.log`):

- Before down: no focused control; viewport offset 4474; option y −9453.
- During the held press: `option:yes` gains focus; offset changes to 4300.5; option y changes to −9626.5.
- The option moves 173.5 points away from the pointer. Mouse-up records no response.

After the fix (`build/fx2-delayed-fixed.log`, `build/fx2-addendum-focused.log`), focus still moves to the option, but offset remains 4474 and the frame remains unchanged. The first release persists `CardResponse.optionID = yes`.

These are app-local native events, not the unlocked WindowServer/cliclick acceptance check. The offscreen fixture remains non-key under the locked console; the failure does not require key-window activation.

## Fix and coverage

ConversationHostingView observes native mouse-down/key-down events **only for its own window**. Pointer-origin focus no longer invokes ScrollViewProxy's centering operation. Keyboard events restore focus scrolling; explicit strip/question jumps still position their targets. The monitor returns every event unchanged, installs when the view joins a window, and is removed on detach/deinit. Its input-source flag is not observable layout state.

The second candidate did not reproduce for question choices: thread typewriter animation is restricted to message cards, so questions render their whole body even with the setting on. Peek typing already reserves the full body height. Held-press tests with typing enabled and disabled verify stationary option frames, recorded answers, and **zero peek expansions**. No speculative reveal/layout change was made.

Coverage includes short and scrolling conversation fixtures, typewriter off/on, the original first-mouse policy assertions, Tab resetting pointer provenance, existing Command-J/Shift-Command-J strip navigation, composer focus and accessibility tests. The test data uses a disposable defaults suite, temporary history, fake messaging/password storage and no runtime, socket, agent, credentials or Keychain.

LM2RenderTests now writes only its build/lm2-renders artifacts. The `readmeName` argument and docs/readme output branch are removed; the designer's harness owns README images.

## Real press acceptance

The opt-in cases `liveChoiceWithCliclick()` and `livePeekWithCliclick()` show only synthetic fixture windows and invoke `/opt/homebrew/bin/cliclick dd:x,y w:120 du:x,y`. No installed Zeus process is stopped and no bridge is started, so there is no socket conflict. The test checks `IOConsoleLocked = No` before showing a fixture or posting an event. The console is currently locked; this live gate remains pending, not passed.

Run from the appdev worktree once unlocked:

```sh
TEST_RUNNER_FX2_LIVE=1 \
TEST_RUNNER_HOME="$PWD/build/fx2-home" \
TEST_RUNNER_CFFIXED_USER_HOME="$PWD/build/fx2-home" \
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/ConversationFirstClickTests test
```

For manual checking, use the same isolated fixture: hold an off-centre choice for about 120 ms and release in place; it must answer without moving. Repeat a peek inline choice while it types: it must answer without expanding. Check Tab/Shift-Tab and Command-J still reveal the focused control; Send, reply chip, strip, notice actions, attachment chips and links keep their first-click behaviour. Do not use the user's sessions or stop installed Zeus.

## Gates

- Focused native suites: 17 tests in four suites passed (including ordinary unlocked-only skips), `build/fx2-addendum-focused.log`.
- `scripts/build.sh`: passed, no new compiler warnings (`build/fx2-addendum-build.log`); the script still reports its existing ambiguous architecture destination warning.
- Full `scripts/test.sh`: packages/offline checks passed; 1,010 app tests in 209 suites completed in 379.408 s, with two assertions in one failing runtime test, `PhaseDLearningTests.rawWordsNeedExplicitPolicyAndReadReceiptNotAnAttempt` (`build/fx2-addendum-full.log`, `build/fx2-addendum-summary.json`). All FX2 cases passed. `LearningRuntimeFixture` sets its runtime clock to 2026-10-14 18:15 UTC but constructs EncryptedJournalStore without that clock. Once real time crossed 2026-10-15 18:15 UTC, the store correctly expired the synthetic words at 24 hours. Platform authorized the exact test-only clock injection in `Runtime/LearningRuntimeTests.swift`; the journal now shares its fixture runtime clock. All 24 tests in the two affected learning suites passed (`build/fx2-fixture-clock.log`). No production retention changes were made. The repeated full `scripts/test.sh` gate passed: 1,010 app tests in 209 suites in 407.394 s, plus package/offline checks (`build/fx2-addendum-full-fixed-clock.log`, `build/fx2-final-summary.json`).
- The opt-in live run stopped both cliclick cases at the locked-console precondition (`build/fx2-cliclick-gate.log`); no global events were posted. This is an unmet live gate, not a live pass.
