# FX2 first-click verification

## Isolation and baseline

Started from main `6ed0826`. Before testing, no installed `/Applications/Zeus.app/Contents/MacOS/Zeus` process was running. The dev test host uses `build/fx2-home` through `TEST_RUNNER_HOME` and `TEST_RUNNER_CFFIXED_USER_HOME`; its fixture uses a private defaults suite, temporary CardStore, fake messaging, and no live runtime/bridge. Events are posted only inside the test application, never through global CGEvents. The fixture refuses to run beside the installed Zeus app.

The console is locked (`IOConsoleLocked = Yes`). A real click into another application cannot be checked in that state. The offscreen native baseline **did not reproduce** the user's double-click failure: before any production change, `ConversationHostingView.acceptsFirstMouse(for:)` returned true over the synthetic choice, and one local down/up pair produced its CardResponse while the panel was non-key. The same result held after disabling the accessibility enhancement used to discover the button's coordinates. Evidence: `build/fx2-baseline-enhanced.log` and `build/fx2-baseline-no-ax.log`. Earlier attempts were fixture discovery/compilation failures, not reproductions.

## Change

Added the explicitly requested hosting-level `acceptsFirstMouse(for:) -> true` policy and the exact panel-behavior sentence in CONTRACT §10. This makes the intended policy explicit instead of inheriting framework behavior; **it is not a demonstrated root-cause fix** on the locked-console baseline. No button-specific handler, editor, responder, keyboard shortcut or VoiceOver behavior was changed.

`ConversationFirstClickTests` hosts the actual ConversationHostingView in a nonactivating NSPanel equivalent (`becomesKeyOnlyIfNeeded = true`). It checks host policy at exposed button locations, the actual hit view over a choice, and that one local mouse-down/up pair persists the expected CardResponse. It restores the app's previous accessibility-enhancement setting afterward.

## Required unlocked hand check

Run only the isolated dev build with a fixture question; stop the installed Zeus first. Do not connect real sessions.

1. Open a question with multiple choices. Click a separate disposable app/window, then click a choice once. Verify one CardResponse and no second click needed. Repeat with the panel already key.
2. Repeat that away-and-back sequence for Send (a nonempty draft), reply chip, Skip, Go to question, journal View, rule OK next time?/Not this/Undo, Ask About This attachment/remove targets, and a fixture link.
3. Put multiline text in the composer, click away, then click within its first line. The first click must place the caret there. Check Escape, Command shortcuts, Tab/Shift-Tab and VoiceOver activation remain correct.

Those real activation-transition checks remain unverified while the console is locked. No LG1 case was added: local event injection does not demonstrate the cross-application WindowServer activation path, and must not be presented as that live gate.

## Results

- `scripts/build.sh`: passed, no new warnings (`build/fx2-build.log`).
- Isolated focused click/focus/accessibility/shortcut run: 14 tests in four suites passed (`build/fx2-focused.log`); tests explicitly requiring an unlocked keyboard session retained their normal skips.
- `TEST_RUNNER_HOME="$PWD/build/fx2-home" TEST_RUNNER_CFFIXED_USER_HOME="$PWD/build/fx2-home" scripts/test.sh`: passed, including 1,007 app tests in 209 suites (465.768 seconds), package suites and offline checks (`build/fx2-full-test.log`). The longer run progressed through the private reconnect/build fixtures; a sample had no animation-worker saturation. No process was stopped or deadline weakened.
- Production change, native fixture and the task-authorized CONTRACT §10 sentence are committed. No global shortcut registration, user sessions, real credentials or installed-app launch was used for the reproduction attempt. Cross-app hand verification remains blocked on the locked console, and the original failure remains unreproduced.
