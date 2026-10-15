# FX1 verification

All four findings in `docs/design/review-lm2-bcd.md` are fixed.

- P1: thread shadow notices read `I'd have bought the usual coffee beans for €14`. The shared presentation normalizer accepts leading would have, would've (straight or curly apostrophe), I'd have, and I would have, case-insensitively. Durable action text stays unchanged, preserving exact purchase approval matching and making legacy records display correctly. Tool copy asks for a past participle and no private details.
- P2: purchase questions and amount-bearing shadow suffixes use `FloatingPointFormatStyle<Double>.Currency(code:)`, with zero fractional digits for whole amounts and two for fractional amounts. Explicit en_IE regressions assert €14, €14.50 and €14.05; runtime tests cover both surfaces and successful exact approval consumption.
- A1: the composed Privacy render uses its real encrypted fixture journal (frame and typing capabilities), a disposable activity root and a synthetic activity source. Screen/Typing controls are enabled without capture consent, so the fixture starts no real capture. Model presence and L1 availability are asserted. The 3000-point render includes every section.
- A2: Rules captions use the same normalizer and prepend `Seen once: would have`, for new and existing action text.

## Ownership

PM explicitly authorized production edits to platform-owned `Zeus/Bridge/ZeusRuntime+RuleActions.swift` and `Packages/ZeusKit/Sources/ZeusProtocol/ZeusRuleTools.swift`. Platform separately approved the exact obsolete currency assertion update in `Zeus/App/Tests/Runtime/PhaseDLearningTests.swift:115`. No other platform files, design-system files or shared contract files changed.

## Results

- `scripts/build.sh`: passed, no new warnings (`build/fx1-build.log`).
- FX1PresentationTests + LM2DRulesTests + opt-in LM2BRenderTests: 6 tests in 3 suites passed (`build/fx1-focused.log`); parameterized tests cover prefix variants and whole/fractional purchases.
- FX1PresentationTests + PhaseDLearningTests + LM2DRulesTests: 15 tests in 3 suites passed (`build/fx1-runtime-focused.log`).
- All-theme, both-appearance Privacy renders are under `build/lm2b-renders/*-privacy-*.png`. Inspected the complete classic-light pane; designer approved the composed pane and copy.
- No full-suite run, per PM instruction while LG2 repairs its gate.
