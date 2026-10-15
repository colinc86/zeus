# LM2-R: design review of the shipped Phase A screens

**Reviewed:** main 417eb5c (LM2-A2, LM2-P and LM2-D5 merged).
- **Real views:**
  - `SettingsView` (Privacy and Rules tabs), with its real `LearningPresentation`
  - `ObservationConsentSheet`
  - `JournalWindowView` (Kept and Sent)
  - `ConversationView` with the runtime's own rule-notice wording and three dropped items
- **Fakes:** journal, rules store and capture source.
- **Coverage:** all 7 bundled themes, light and dark.
- **Renders:** `scripts/design-harness/render.sh "lm2Review()"` (140 images) and `"lm2ReviewFixes()"`. A selection is in `docs/design/lm2-review/`.
- **Specs compared:** `PRIVACY.md` §1–8 and the `lm2/lm2-*` mock-ups.

## Fixed on this branch (ZeusDesign)

| # | Fix | Where |
|---|---|---|
| D1 | `View.zeusThemeAppearance(_:)`: a window follows a fixed-appearance theme's light or dark mode (`preferredColorScheme(theme.fixedAppearance)`). With it applied, Parchment in dark mode reads correctly (`lm2-review/lm2r-fix-parchment-rules__dark-pixel.png`). | `ZeusThemes.swift` |
| D2 | `ZeusAttachmentChip` (icon, label, optional action such as "Work in this folder", pixel × remove; VoiceOver "Remove <label>") and `ZeusChipFlow` (chips wrap instead of scrolling sideways). See `lm2-review/lm2r-fix-chips__light-pixel.png`. | `ZeusComponents.swift`, `ZeusAttachmentChipTests` |
| D3 | `PRIVACY.md` §6: the Phase A shadow-line wording, for use until rules carry outcome text. | `PRIVACY.md` |

## Appdev (Zeus/Settings, Zeus/Cards)

| # | Severity | Issue | Fix |
|---|---|---|---|
| A1 | **High** | Settings, What Zeus Kept and their sheets draw theme text on the *system* window background. 5 of 7 themes have a fixed appearance (Parchment, Pocket and Sorbet are light-only; Midnight and Phosphor are dark-only), so in the other system mode their text is close to invisible (`lm2r-parchment-rules__dark-pixel.png`). This predates LM2 and affects every Settings pane. | Add `.zeusThemeAppearance(settings.currentTheme)` to `SettingsView.body` and to `JournalWindowView.body`. Sheets inherit it. |
| A2 | **High** | Composer draft attachments (`ConversationView.attachmentDraft`): a horizontal `ScrollView` hides items past the panel edge (the third of three dropped items isn't visible at the default width), and "Remove" renders as a grey system button in the pixel panel (`lm2r-classic-thread__light-pixel.png`). | Replace with `ZeusChipFlow { ForEach(...) { ZeusAttachmentChip(item, actionTitle: item.kind == .folder && managed?.enabled == true ? "Work in this folder" : nil, onAction: { workInFolder(item.target) }, onRemove: { model.removeAttachment(id: item.id) }) } }`. |
| A3 | Medium | Privacy: with Level 2 on "Everywhere except my private list", the same private list (9 rows) is shown a second time under Level 2. | In that mode Level 2 shows only its caption: "Apps on your private list (above) are never recorded at any level." The list itself appears once, under Apps and timing. |
| A4 | Medium | Privacy order and hierarchy: Level 1's Record in, list and Keep for come after "What Zeus has recorded" and "Notes to your assistant". "Delete Everything…" sits in the middle of the pane though it deletes the whole journal. "What Zeus has recorded" and "Notes to your assistant" use the same title style as the levels. | Per level: switch, caption, Record in, list, Keep for. Then Level 1's "What Zeus has recorded" and "Notes" as `settingsHeading`. Put Pause for Today and Delete Everything… at the end of the pane, after What Zeus kept. |
| A5 | Low | "What Zeus kept" has no caption. | "Every record exactly as stored, and everything sent to your assistant." (PRIVACY.md §2) |
| A6 | Low | The Safari caption under its allow-list row starts at the left edge (earlier nit). | Indent it to the app name (16-pt icon plus spacing). |
| A7 | Medium | Journal rows repeat the app name: "9:52 AM · Xcode", then "Xcode" on its own line, for every window record (`lm2r-classic-kept__light-pixel.png`). | Hide the description line when it equals the header's app name. |
| A8 | Low | A private-time record's header reads "Zeus". | Use "Private" for private-time records. Keep "Zeus" for Zeus's own items. Please check this against real Level 1 private events. |
| A9 | Low | The rule trigger text reads "in Xcode; when tests failing" and "18:00–09:00 on Monday, Tuesday, Wednesday, Thursday, Friday". | Join parts with " · ". Weekdays 2–6 become "Weekdays", 1 and 7 become "Weekends", any other days use short names ("Mon, Wed"). For example: "Weekdays 18:00–09:00", "in Xcode · when tests failing". |
| A10 | Low | **Confidence meter gap:** in `RuleConfidence`, one `HStack(spacing: 3)` holds both the cells and the word, so "Fairly sure" sits against the meter. | Put the cells in their own `HStack(spacing: 1)`, inside an `HStack(spacing: 6)` with the word. |

## Platform (Zeus/Bridge/ZeusRuntime+Learning.swift, `reconnectRuleNotices`)

| # | Now | Should be |
|---|---|---|
| P1 | "I'd have: Send a short update to the team" · OK next time? | "I'd have acted on “Send a short update to the team”" · OK next time? |
| P2 | "OK. I will do that from now on." · Undo | "OK. I'll do that from now on." · Undo |
| P3 | "Rule retired: <sentence>" for **any** non-active state after the shadow line, including "Not This" (which makes it proposed, not retired) | Retired: "Retired: “<sentence>”" · Review. After Not This: "Got it. I won't." with no action. |

## Matches the spec

- **Consent sheet:** keeps and never lists, the example record, the Safari caption, the caveat, the Accessibility line, and the buttons.
- **Coins:** both modes work, Safari's caption appears when it's in the allow list, and retention is 7/30/90.
- **Kept and Sent:**
  - Toolbar: ‹ Today ›, the Zeus pickers and search.
  - Placeholders are in secondary text, and the footer is right-aligned.
  - The ledger row has the ■ session dot and its word count.
- **Rules:**
  - Sections with counts, the dial with its three captions, the trailing toggle and ⋯, and Seen once. Zeus didn't act.
  - Turn On and Dismiss, Show 1 retired, Add Rule…, and the empty state.
- **The conversation in all themes:** "New rule: … · Review" and "3 new rules · Review" read well in every theme.
