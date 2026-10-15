# LM2-R2: design review of the shipped Phase B, C and D screens

**Reviewed:** main 1786a11 (Phases A–D merged).
- **Real views**, rendered by the app's own render suites (`LM2BRenderTests`, `LM2CTypingRenderTests`, `LM2DRenderTests`) in all 7 bundled themes, light and dark: 650 images under `build/lm2{b,c,d}-renders/`. Those suites use the production views with fake stores and synthetic frames, which is what this review needs.
- **Copy audit:** every quoted string in `PRIVACY.md` §9–§11 and `CONVERSATION.md` §16 was checked against the shipped sources, and the runtime's thread-line formats were read directly (`ZeusRuntime+Journal.swift`, `ZeusRuntime+RuleActions.swift`).
- **Compared against:** `PRIVACY.md` §9–§11, `CONVERSATION.md` §16, and the `lm2b/lm2c/lm2d` mock-ups.

## Matches the spec

- **Screen section:** switch, caption, the macOS indicator caption, Record in, cap (4/12/30 an hour), Keep descriptions for (7/30/90), "Pictures are deleted after 7 days", and the permission states (waiting, reopen, denied/revoked) and paused captions (video call, presenting, password field). Safari row caption and the consent sheet with its example, Safari note and both caveats.
- **Typing section:** fixed "Only in apps I choose", the allow list with the Safari caption, Keep topics above Keep the words with the dynamic caption, "Paused: private input.", the Input Monitoring states, the Apple Intelligence-off state, and the consent sheets (full and short). Raw on request switches sit under each level with the §11.1 captions; the raw sheets match §11.1.
- **What Zeus Kept:** picture rows (thumbnail, "Picture · N days left", "Picture not kept: it looked private", "No picture"), the picture detail (one covered line, solid fill with outline, legend and counts on separate lines, zero counts hidden, Kept until, Delete Picture / Delete Both… / Close), typing groups by app and hour with topic first and the `‹pasted›` chip, journal-answer rows with "Includes 1 picture" / "Includes your words", the covered thumbnail, and the refused row.
- **Composer:** Ask About This chips (Window, Page, Selection, Picture with thumbnail) with the caption, wrapping, and the pixel ×.
- **Thread lines:** "Looked at your journal: Tue 14:00–15:30 · View" and every §11.2 variant (including 2 pictures / your words / descriptions only / nothing for / N times), the two-action shadow line, the acted line with Undo or Not again, "Got it. I won't.", "Rule turned off · Review", and the three retired reasons.
- **Rules:** sections, dial, "Seen once: …", the spend row's "Always asks" (PM decision), Why? with dated labelled outcomes, exact sources, pixel-drawn glyphs and "Always asks · Fairly sure".
- **Menu:** "Private input: Zeus isn't noting typing" as a disabled status line while Level 4 is on and secure input is active.
- **Themes:** every surface reads correctly in all 7 themes in both system modes, including the fixed-appearance themes in their opposite mode (the LM2-R A1 fix held through B–D).

## Fixed on this branch

| # | Fix | Where |
|---|---|---|
| D1 | `PRIVACY.md`: the status table and section tags now say Phases B, C and D ship; §11.4 records the shipped "Did: …" wording (PM task) next to the spec's verb form. | `docs/design/PRIVACY.md` |
| D2 | `CONVERSATION.md` §16: status updated to shipped for B–D. | `docs/design/CONVERSATION.md` |

No ZeusDesign change was needed.

## Platform (Zeus/Bridge, ZeusProtocol)

| # | Severity | Issue | Fix |
|---|---|---|---|
| P1 | **Medium** | The shadow line reads "I'd have acted on “would have bought coffee for €14”": `zeus_rule_shadow`'s field is `wouldHave`, agents send it starting with "would have", and `ZeusRuntime+RuleActions.swift:95` wraps that whole string. Spec §11.4 wants "I'd have bought the usual coffee beans for €14 · OK next time?". | Normalise: strip a leading "would have " / "I'd have " / "I would have " (case-insensitive) from `wouldHave`, then build `"I'd have \(rest)"`. Say in the tool description that `wouldHave` starts with the past participle ("sent …", "bought …") and contains nothing private. Keep "Did: \(did)" as the PM decided. |
| P2 | Low | The purchase question's body prints `String(action.amount ?? 0) + " " + currency` ("14.0 EUR"). | Format with `FloatingPointFormatStyle.Currency(code:)` so it reads "€14" / "€14.50"; same for the "— amount currency" suffix on the shadow line. |

## Appdev (Zeus/Settings, Zeus/App/Tests)

| # | Severity | Issue | Fix |
|---|---|---|---|
| A1 | Low (test) | `LM2BRenderTests` renders the composed Privacy pane with `LM2JournalFake` and `LearnFromMe(root: nil)`, so the pane render has no Screen or Typing section and the Level 1 switch is greyed. The product is fine (`ShellController` installs the encrypted journal, which is frame- and typing-capable), but the render can't catch composition regressions. | Install the `EncryptedJournalStore` the test already builds for pictures, and give `LearnFromMe` a temporary root, so `learning.screen`/`learning.typing` exist and the pane renders all four levels. |
| A2 | Low | The Rules row's "Seen once: \(text)" depends on P1's normalisation: once the runtime strips "would have", prepend it here ("Seen once: would have \(rest)") so the row keeps reading as a sentence. | Coordinate with P1. |

## Not reviewed here

- Behaviour under real Screen Recording / Input Monitoring permission, and real captures: covered by appdev's and platform's own isolated probes; this review is renders and copy only.
- The full test suite was not run (platform is repairing it on this machine); `build.sh` and the design/copy suites only.
