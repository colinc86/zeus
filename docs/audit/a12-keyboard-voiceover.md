# A12 — keyboard and VoiceOver

2026-10-14 · appdev · base `b7dc9f6`.

The app and shared-control fixes are implemented. Verification uses real offscreen `NSHostingView`/`NSPanel` trees,
`NSAccessibility` actions, native key-view loops matched spatially to accessibility-node bounds, isolated defaults,
fake credentials/controller/activity source, and disposable files. Nothing opens a user's agent, reads credentials,
changes system keyboard preferences, posts global events, uses Computer Use, or records the screen.

**Verification limit:** macOS's lock-screen shield is above the fixture windows (`elementWindow(25) ... shield(2001)`).
The application stays inactive and the windows cannot become key. Accessibility trees/actions, Tab loops, Escape key
equivalents and width key equivalents are inspectable; actual SwiftUI Space/Return activation and the OS's initial
first-responder assignment cannot be claimed from an inactive window. Two app tests and one package test explicitly
opt into native key activation on an unlocked Mac. VoiceOver speech itself was not recorded or listened to; the assertions inspect the
same in-process accessibility labels, values, hints and actions.

## Findings

| Surface | Control | Problem / evidence | Fix / result |
|---|---|---|---|
| Status strip | Skip | The control's native AX tree had label `Skip` and no shortcut hint; no visible help was supplied. | Tooltip `Skip (⇧⌘J)`; AX label remains `Skip`, hint `Command-Shift-J`, per designer approval. Native assertion checks the hint. |
| Status strip | Jump, Skip, icons | Two links produced four native Tab stops, with identical bounds in pairs. Explicit `.focusable()` added a second target around an already-focusable Button. | Disable the inner target and own one wrapper. Native regression: two links → two stops; two links + three enabled icons → five; disabled Clear remains labelled and takes no Tab stop. Space/Return handlers consume one press. |
| Conversation notices | Undo / Show now | Resolving a notice changed the visible caption to `Undone` without announcing the action result. Bare action labels also gave no context among several notices. | Contextual action labels; announce `summary. Undone.` when this mounted line changes to resolved. No announcement when reopening existing history. Native AX actions plus captured announcement callbacks prove one-shot behavior. |
| Conversation notices | Daily summary View / Hide | Several bare `View` controls were indistinguishable; expansion had no spoken value. | `View: Sent your daily summary` / `Hide: …`, with `Collapsed` / `Expanded`; exact sent text remains accessible. Native actions prove expand/collapse and values. |
| Privacy | Add App… | The picker added an entry silently. Re-selecting an existing entry was also silent. | Visible and spoken `Added X to your private list.` / `X is already on your private list.`; Cancel announces nothing. The button is disabled during the picker. Test completes an injected picker with a disposable `.app` bundle; no installed app inventory is read. |
| Privacy sheet | Not Now / Turn On | No explicit initial safe focus; adding focus to a styled button naïvely produced a duplicate stop. | Request Not Now using the wrapper's single focus binding. Two stops, in Not Now → Turn On order. Escape invokes Not Now and never enables learning. Unlocked test asserts initial focus and Return/Space activation. |
| Appearance, imports, Settings tabs and segmented choices | Theme/font choices; Import / Open Example / Open Folder; Replace / Cancel | Styled buttons did not draw the theme's focus ring. Plain theme/character cards had selection chrome but no explicit keyboard-focus chrome. Standard button activation also depended on the system activation-focus behavior. | Shared app `KeyboardButton` owns one editing-focus target, a 1-px `focusRing` outline and Space/Return dispatch, retaining native button AX actions. Appearance's complete 12-stop loop and every Settings tab are asserted. Import confirmations retain Cancel and Escape. |
| General | Assistant control / install switches | The custom checkbox had no explicit theme focus ring. | Shared checkbox owns one focus target, the existing checkbox outline in `focusRing`, a minimum 22-pt target and explicit Space activation. Return falls through to the window, per designer review. AX checked state, action, dependent-disabled state and removal from Tab order are asserted; saved update preference is preserved. |
| General | Shortcut key picker | AX exposed only the current letter (`Z`) without the control's purpose. | Explicit label `Shortcut key`; its position between Enable global shortcut and modifier checkboxes is inspected. |
| Assistant | Agent / permission choice rows | An unselected keyboard-focused row had no explicit token-based focus marker. | One focus target and 1-px theme outline for each enabled choice, with Space selection; Return falls through to the window, per designer review. Native component test checks exactly two enabled choices plus one checkbox; disabled choices take no stop; AX selection action still changes the binding. |
| Assistant confirmations | Switch Now / Later; Stop / Keep Running | Existing safe-focus and Escape behavior needed to survive the button-focus fix. | One shared focus binding per cancel control. Native trees, single cancel stop, Escape, no fresh conversation and retained running controller are asserted. OS initial-focus check remains part of unlocked verification. |
| Character | Ghost sliders | No new defect found in labels/values/order. | AX reports `Idle opacity` / `30 percent` and `Idle fade delay` / `30 seconds`; both occur in the native Tab loop. Arrow-key adjustment has an unlocked native regression. Ghost Reduce Motion policy already makes fade duration zero. |
| Conversation | Resize handle / Reset width | Drag and AX increment/decrement existed, but no keyboard equivalent/reset; the splitter lacked a spoken width. | ⌘⌥←/→ changes width by 20 points from anywhere in this window. Focused handle also accepts ←/→. Both paths use the existing clamp/persistence path. Reset width is in the panel and handle context menus and the splitter's AX custom actions. AX numeric value + `N points`, help and value-change notification added. Tests cover modifiers, bounds, reset, persistence, away edge, host forwarding and draft preservation. |
| Conversation | Resize focus | The new native keyboard target must follow live theme edits. | A zero-sized, AX-hidden SwiftUI/native bridge applies the environment's `focusRing` to the handle; unchanged colors do not invalidate drawing. All seven live themes are checked without replacing the editor/draft. |
| All listed surfaces | Reduce Motion | No additional animation needed for these controls. | Focus rings, notices, checkboxes and width nudges change immediately. Existing conversation jump policy uses the Reduce Motion branch; character animation inputs and ghost fade policy already consume Reduce Motion. Existing corresponding regression suites remain in the full gate. |

The designer authorized the limited `ZeusStatusStrip.swift` and `ZeusManagedSession.swift` edits. No model factories,
public API signatures, copy factories, fonts or new colors changed; production ZeusDesign remains AppKit-free.

The controls deliberately own editing focus and handle activation explicitly. Apple's [activation-focus documentation](https://developer.apple.com/documentation/swiftui/focusinteractions/activate)
explains why default activation-only targets otherwise depend on system-wide all-controls keyboard navigation.
No system preference is changed. Modified Command/Option/Control Space/Return falls through instead of invoking an action.
The glyph audit excludes direct native `.help("…")` arguments, which use the system tooltip font; a regression ensures
rendered `Text` on the same line is still checked.

## Reproduce

```sh
scripts/build.sh
scripts/test.sh
TEST_RUNNER_ZEUS_A12_EVIDENCE=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -only-testing:ZeusTests/A12AccessibilityTests -only-testing:ZeusTests/A12ResizeTests test
```

Renders are native offscreen view bitmaps, not screen captures. The focused tests write trees and renders to
`build/a12-evidence/` when the evidence flag is set. Checked-in evidence is under `TestFixtures/live/a12/`.
Each theme render includes a tiny reference swatch at the top left: the pixel assertion compares the requested Not Now
focus ring to that same theme token rendered through the same display profile. Both light and dark appearances are
covered for all seven themes. Focus outlines use one UI pixel (`ZeusTheme.pixel`, 2 points), matching existing chrome.

On an **unlocked** Mac, add `TEST_RUNNER_ZEUS_A12_LIVE_KEYS=1` to the focused command. The two opt-in tests require the
offscreen fixture to become key before sending scoped `NSEvent`s; they do not retry a failed activation or post globally.
They exercise initial Not Now focus, Tab, Space, Return, theme selection, checkbox, Undo, Skip and a ghost slider arrow.
For the shared agent/permission choice rows and checkbox, separately run:

```sh
ZEUS_A12_LIVE_KEYS=1 swift test --package-path Packages/ZeusKit --scratch-path build/ZeusKit \
  --filter ZeusKeyboardAccessibilityTests
```

For final human VoiceOver acceptance: Tab through the strip and its enabled icons; Undo and Show now; View/Hide a summary;
Appearance themes/font/imports; General switches; Privacy switches, Add App and first-run sheet; Switch Now/Later and
Stop/Keep Running; ghost sliders; width shortcuts/reset. Check plain labels/values and completion announcements. Escape
must cancel each confirmation. With Reduce Motion on, jumps and ghost fades must remain still.

PM documentation follow-up: CONTRACT §7's width paragraph and the conversation keyboard table should include
⌘⌥←/→ and Reset width. Shared/CONTRACT were not edited.

## Gates

- `scripts/build.sh`: passed on final code `c41c882`; no new compiler warnings. The existing ambiguous-destination
  warning remains.
- `scripts/test.sh`: passed on final code: **229 package tests**, **747 app tests in 155 suites**, plus the offline release
  checks. Logs: `build/a12-build.log`, `build/a12-test.log` in the worktree.
- **Three new hardware-gated tests remain unrun:** two app keyboard tests and one shared-control keyboard test.
  They are explicitly skipped by default and must be enabled on an unlocked Mac with the commands above. These counts
  are the runner's declared totals, including skips; no key-activation success is inferred from a skipped test.
- The focused native assertions pass: complete Appearance/Privacy/tab order, single focus stops, disabled states,
  contextual labels/values, picker and Undo announcements, Escape, width key equivalents, bounds/reset/persistence,
  unsent-draft preservation, and ring tokens for all **14 theme/appearance combinations**.
- Designer review approved `c41c882` after the Space-only and UI-pixel outline follow-ups, conditional on the final
  gates above. No additional designer concerns remain. Platform was invited to cross-review; no response was received
  while it was working on SA3.

Code commits: `697cb0b`, `e9a58a1`, `6b2f070`, `2393c06`, `e64b92f`, `a92c397`, `c41c882`.
