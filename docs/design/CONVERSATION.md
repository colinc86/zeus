# Conversation Panel: Visual and Interaction Spec (v1)

**Implements:** CONTRACT §10 (including §10.7, the peek bubble, in §14). **Audience:** appdev (A5). **Supersedes:** the card-stack parts of CARDS.md (§1 Anatomy, §2, §3, §5 stack/pager, §6). CARDS.md still governs the badge, the delivery-warning marker, the dialog tail and the do/don'ts.

**References:**
- Rendered: `docs/design/conversation-d5.png`
- Live: the `#Preview("Conversation")` in `ZeusConversationGallery.swift`
- Components: `Packages/ZeusKit/Sources/ZeusDesign/ZeusConversation.swift`

**Colors:** read `@Environment(\.zeusPalette)`. It follows the color scheme and Increase Contrast (`ZeusPalette.lightHighContrast` / `darkHighContrast`, AAA text). Never fade text with `.opacity`; use `secondaryText` / `mutedText`. Symbols the pixel font lacks (✓ ✕ ↩ ◀ ▶ ↑) are `ZeusGlyph`s, and `ZeusFonts.pixelFontMissingGlyphs(in:)` checks any new UI string.

**Type:** all text uses the `.zeusFont(_:)` roles. With the default pixel font, Departure Mono (D10), that's **16.5 pt for titles and 11 pt for everything else**, on the font's 11 px/em grid so it renders crisp. SF Mono is the user's alternative. Departure Mono has one weight and no italic, so in the pixel font markdown **bold** renders in the gold title color instead of a bold face and *italic* in the secondary color, and inline `code` gets a subtle tint (both fonts). Block markdown (F9) renders in the same single `Text`: headings as bold lines, `•`/`–`/`1.` list markers with nested indents (one newline between items), `▌` quote bars in the secondary color, fenced code as a tinted block padded to one width with the language tag dropped, tables as `│` rows, and rules as a short `─` line. There's a blank line between other blocks. Paragraph line breaks are kept. Use `ZeusMarkdown.spokenText(_:)` for accessibility labels; it drops the decorations. Render bodies with `ZeusMarkdown.attributed(_:choice:palette:)` or `ZeusMarkdownText`.

**The human's brief:** *seamless, intuitive, keyboard-driven, minimal clicks.* Every rule below serves one of these:
- **No dead ends.** Nothing ever has to be dismissed.
- **The composer is always ready.**
- **Every action has a key.**

---

## 1. Anatomy

```
 ┌──────────────────────────────────────────┐ ← .zeusDialog(tail:), width 380
 │ ───────────── Today 8:02 ─────────────── │ ← ZeusThreadDivider
 │ ■ Claude · Zeus                          │ ← ZeusSessionLabel (only if >1 session, §3)
 │ ┌ Talk tomorrow ─────────────── 8:02 ┐   │ ← agent ZeusBubble + ZeusBubbleHeader
 │ │ Your talk is tomorrow at 10:00…    │   │
 │ │ ✓ No                               │   │ ← ZeusOptionButtons(.answered)
 │ └────────────────────────────────────┘   │
 │          ┌ No, can you take a pass? ┐    │ ← user ZeusBubble (right)
 │ ┌ Ship the build? ───────────── 8:40 ┐   │ ← gold frame = high priority
 │ │ [Ship it ⌘1] [Not yet ⌘2]          │   │ ← ZeusOptionButtons(.open(shortcuts: true))
 │ └────────────────────────────────────┘   │
 │ ┌ ▪▪▪ Uploading v0.3 ┐                   │ ← ZeusTypingIndicator: last row while an agent works (§11)
 │ └ ▬▬▬▬▬▬▬▬▬░░░░░░ 40% ┘                   │
 │                             [↓ 2 new]    │ ← ZeusJumpToLatest (only when scrolled up)
 │ ? Waiting for your answer · Skip ▣ ⊞ ▥ ✲ │ ← ZeusStatusStrip (§15), always shown
 ├──────────────────────────────────────────┤ ← its 1 px rule, palette.divider
 │ ▌↩ Replying to: Ship the build?       ✕  │ ← ZeusReplyChip (inside ZeusComposer)
 │ [ Message Claude…                ] [↑]   │ ← ZeusComposer
 └─────────────────────▼────────────────────┘
```

There's no title bar, no close button and no pager. The thread scrolls; the composer is pinned below it.

## 2. Panel size, placement and lifecycle

**Size**
- **Width:** `ZeusTheme.Conversation.panelWidth` (380 pt, frame included). Content width = 380 − 2·borderWidth − 2·Spacing.m = **348 pt**.
- **Thread height:** fits its content, between `minThreadHeight` (160) and `min(maxThreadHeight 520, maxHeightFraction 0.7 × screen.visibleFrame.height − composer height)`. Past that it scrolls.
- **Composer:** 1–6 lines (`composerLines`), then scrolls inside. The panel grows upward as the composer grows when anchored above Zeus, and downward when anchored below.

**Placement and tail**
- Anchor as in CARDS.md §4: above the avatar when there's room, otherwise below. Center on the avatar's anchor x, clamp to the visible frame with 8 pt of margin, and point the tail at the avatar (`offset` clamped to [16, width − 16]).
- The panel follows the avatar while it's dragged, in the same frame.

**Opening**
- Triggers: clicking Zeus, ⌥⌘Z, or the context menu's *Talk to Zeus*.
- The panel opens with the composer focused and the thread scrolled to the bottom, then marks everything visible as seen (§7).
- If the panel is already open, a click on Zeus closes it. ⌥⌘Z focuses the composer if the panel isn't key, and closes the panel if it is.

**Closing**
- Triggers: Esc, clicking Zeus, ⌥⌘Z, or clicking into another app (the panel resigns key).
- Focus returns to the previously active app. The panel is a non-activating `NSPanel` that can become key, so typing works without activating Zeus.
- The **draft and the chip choice persist** across close/open until sent, for the life of the app process.

**Motion**
- Appear: as CARDS.md §7 (fade + 3 px rise, 120 ms; opacity only under Reduce Motion).
- Disappear: a 80 ms fade.

## 3. Thread layout

**Order**
- Strictly chronological by `createdAt`. A progress card **updates in place** and never moves.
- High priority doesn't reorder anything. It gets the gold frame, and it counts toward the badge and the alert state as before.

**Spacing**
- `Conversation.spacing` (10) between items.
- `groupedSpacing` (4) between consecutive bubbles from the same speaker **and** session less than 2 min apart.
- Bubbles in a group repeat neither the session label nor the header time.

**Dividers**
- Insert a `ZeusThreadDivider` before the first item, and wherever two consecutive items are more than **10 min** apart or fall on different days.
- Format:
  - "Today 8:02"
  - "Yesterday 17:40"
  - "Mon 12 Oct 9:15" for older days within the year
  - "12 Oct 2025 9:15" for older years
- Use the 24 h or 12 h clock per the system locale (`Date.FormatStyle`).

**Session labels** (CONTRACT §10.1; revised for Q2 DES-8)
- Shown only when the loaded thread contains cards from **more than one** `sessionKey`.
- **Placement: when the session changes.** Label an agent bubble when the previous agent bubble came from a different session, or when it's the first agent bubble after a `ZeusThreadDivider`. User bubbles in between don't count, so a back-and-forth with one session shows its label once, not after every reply. User bubbles never get a label.
- **One label everywhere.** The thread, the activity indicator (§11), Settings → Agent, the menu and the composer placeholder all use one function (appdev: shared with `SessionLabels`):
  - `"<Agent> · <folder>"`. Agent is the display name: Claude, Codex, OpenCode. Folder is the last path component of `cwd`. Examples: "Claude · Website", "Codex · zeus-app".
  - If two live sessions have the same agent and last component but different paths, use the last two components for both: "Claude · ParkHub/Zeus" and "Claude · Archive/Zeus".
  - **Same agent, same folder:** the session that connected first keeps the plain label. Each later one gets the lowest free ordinal, `" · 2"`, `" · 3"`. A session keeps its ordinal for its lifetime, so earlier bubbles never change their meaning. The dot color is extra, never the only difference (four colors collide).
  - A tmux pane is shown only when the key carries a real pane id (`%N`): `"Claude · Website · pane 3"`. Anything else after `#` in a key (the `pid.start` process identity) is never shown.
  - **Disconnected sessions** keep the label they had while connected. When the thread is reloaded with no record of it, build the label from the key's agent and `cwd` alone, with no `#…` suffix.
  - Settings shows this label as the row's title. Process details (pid, start time, connected-since) go on one caption line under it, once.
- Color: `ZeusSessionLabel.colorIndex(for: sessionKey)`.

**History**
- Load all persisted cards from CardStore. Render the thread with a `LazyVStack` inside a `ScrollViewReader`.
- If more than 300 items exist, load the newest 300 and fetch older pages when scrolled to the top.

**Names (R3c, D2-8).** One rule, from `ZeusAgentName`:
- **Product name** ("Claude Code", "Codex", "OpenCode") in Settings and lifecycle copy (status panel, blocked card, menu status).
- **Short name** ("Claude", "Codex", "OpenCode") in session labels, VoiceOver speakers (thread and peek: "Claude says: …") and the composer ("Message Claude…").
- **"your assistant"** only before any agent is chosen ("Message your assistant…") and in copy that doesn't depend on which agent it is.
- **"Zeus"** is the speaker only for Zeus's own cards (the Welcome card, the blocked card).

## 4. Bubble types

Every bubble is a `ZeusBubble`. The table shows what goes inside it, mapped from `Card`.

| Card | Bubble | Contents, in order |
|---|---|---|
| `message` | agent | `ZeusBubbleHeader(title, time)` if `title`, then the body |
| `question`, open | agent | header, body, `ZeusOptionButtons(.open(shortcuts:))`. Shortcuts are only on the newest open question that has options (§8). |
| `question`, answered | agent | header, body, `ZeusOptionButtons(.answered(optionID:))` showing only "✓ <label>", or nothing for a text answer. **Plus** a user bubble with the answer, placed **chronologically at the time of answering** (amended in D12: it used to say "right after the question card"). When the entry just before it isn't its question, add a caption above it: "↩ <question title>" (secondaryText, `.caption`, right-aligned). |
| `content` | agent | header, body, one `ZeusAttachmentRow` per attachment, then actions as `ZeusOptionButtons` (same open/answered rules as a question) |
| `progress` | agent | header (title, or the body's first line), `ZeusProgressRow(value: card.progress)`. Updates in place. |
| any card with `progress != nil` | agent | as its kind, plus `ZeusProgressRow` before the options |
| `userMessage` | user | the text |
| dismissed / expired | agent, `muted: true` | Content as before, but options become `.closed`; attachments stay usable (they're still useful). No receipt line. The bubble recedes with color, not opacity: a flat panel-colored fill, a light outline, and `mutedText` for the title, body and time (`\.zeusMuted` tells `ZeusBubbleHeader`), so it keeps WCAG AA. |
| `priority == .high` | `highPriority: true` | gold frame; same contents |

**Bodies**
- Render bodies as `Text(ZeusMarkdown.attributed(body, choice: fontChoice, palette: palette))` with `.textSelection(.enabled)`. Text without block syntax parses as inline markdown with whitespace preserved; text with block syntax gets the block layout from "Type" above. A line limit (the peek's 6 lines) counts rendered lines.
- Links open through `NSWorkspace`.

**User answer bubbles**
- An option answer shows the option label.
- A text answer shows the text.
- An answer from the phone (`device == .ios`) adds a caption, " · from iPhone", under the bubble (secondaryText).

**Send states for user bubbles** (the result of `sendUserMessage`, as in A3's `MessageSendResult`)
- **Sending:** the bubble at 85% opacity, or better a "Sending…" caption at full strength. 60% fails AA (`ZeusContrastAuditTests`).
- **Delivered:** normal; no caption.
- **Queued:** a caption under the bubble: "Queued: <reason>" (secondaryText).
- **Failed:** a caption "Not sent: <reason> · Retry" in `palette.destructive`. *Retry* is a plain-style button that resends the same text.

## 5. The composer and reply chip (CONTRACT §10.2)

Use `ZeusComposer`.

**Placeholder:** "Message <assistant name>…", where the assistant is the A3 assistant session's `clientName`, or "Zeus" if there's none.

**Reply target.** The target is the **newest** card where `kind == .question`, `status == .open` and `input != nil`.
- If there's a target and the user hasn't cleared it, pass its title (or the first 40 characters of its body, with "…") as `replyingTo`. Sending then calls `responseHandler` with `CardResponse(text:)` for that card.
- Otherwise, sending calls `sendUserMessage(text)`.
- Clearing the chip (✕, ⌘K, or Backspace in an empty field) clears it **for that card only**. A newer question that arrives brings the chip back.
- Questions that have options but no `input` never produce a chip. They're answered with buttons or ⌘1–9, and typing sends a plain message.

**After send**
- Clear the field and keep focus.
- The user bubble appears immediately (§4 send states), and the thread scrolls to the bottom.

**Placeholder alignment.** Use `ZeusComposer` or `TextField(…, axis: .vertical)`. **Never** overlay a `Text` placeholder on a `TextEditor`: that's what A3 did, and it caused the reported misalignment. NSTextView's 5 pt line-fragment padding and line metrics can't be matched by an overlay. This is proven in `ZeusComposerAlignmentTests` for both fonts, single-line and multiline.

## 6. Empty state

- If no cards were ever loaded, the thread area shows `ZeusEmptyThread(assistantName:)` at `minThreadHeight`.
- If no assistant session is connected, pass `nil` with `onOpenSettings`; the button opens Settings → Agent.
- The composer still works in both cases: a message with no assistant goes through `sendUserMessage` and shows as Queued.

## 7. Scrolling, seen and "jump to latest"

- **At bottom** means the last item's bottom edge is within 24 pt of the visible bottom.
- **A new item arrives while at bottom:** scroll to it, animated 150 ms ease-out (or instantly under Reduce Motion). It's seen at once if the panel is open.
- **A new item arrives while scrolled up:** don't move. Show `ZeusJumpToLatest(newCount:)` overlaid bottom-trailing on the thread, 4 pt above the rule.
  - Clicking it or pressing ⌘↓ scrolls to the bottom.
  - The count is the number of unseen items below the viewport.
  - Progress updates never count.
- **Seen.** An item is marked seen when the panel is open and the item has been inside the visible thread area for at least 300 ms (an `onAppear` debounce is fine).
  - Opening the panel scrolls to the bottom, so everything that shows is seen.
  - This drives the badge (unseen count) and the `alert` state (CONTRACT §10.3).
- **Thread size changes from the composer** (wrapping to more lines) keep the bottom pinned when the thread was at bottom.

## 8. Keyboard map

All keys work while the panel is key. Only ⌥⌘Z is global.

| Key | Where | Action |
|---|---|---|
| ⌥⌘Z | anywhere (global; configurable in Settings → Agent) | Open the panel with the composer focused, or close it if it's already key |
| Return | composer | Send. Does nothing if the text is blank. |
| ⇧Return or ⌥Return | composer | New line at the caret (handled by `ZeusComposer`) |
| Backspace | composer, empty, chip showing | Clear the reply chip (handled by `ZeusComposer`) |
| ⌘K | panel | Clear the reply chip (handled by `ZeusComposer`) |
| ⌘1 … ⌘9 | panel | Pick option N on the **newest open question or content card that has options**; only that bubble shows the ⌘N hints. Works even while typing. |
| ⌘↓ | panel | Jump to latest (handled by `ZeusJumpToLatest`; add a hidden button with the same shortcut when the pill isn't shown) |
| Tab / ⇧Tab | panel | Native key-view traversal; Zeus doesn't intercept Tab. Focus moves in reading order through every control in the loaded thread, then the composer, and wraps. See the note below. |
| Space | a focused button | Activate it (standard) |
| Esc | panel | Close the panel and return focus. If the warning popover is open, close only the popover. |
| ⌘, | panel | Settings |

Notes:
- Register ⌥⌘Z with Carbon `RegisterEventHotKey`. It needs no Accessibility permission. If registration fails because another app owns the combination, show "⌥⌘Z is in use; choose another" in Settings → Agent.
- Tab order: "Load earlier messages", then oldest to newest, each bubble's controls: open option buttons, the Welcome card's buttons, Retry on a failed send, and each attachment row's Reveal then Open. The composer comes last. Answered, closed and muted bubbles have no stops. Every thread control is `.focusable()` with a unique focus identity (entry + control). Then Tab reaches it without the system's Keyboard Navigation setting, and two cards that reuse an option ID never share a stop.
- Focusing a thread control scrolls it to the middle of the thread and stops following new messages (as if the person had scrolled), until ⌘↓ or the pill.
- In the composer, Tab leaves the field; it never inserts a tab character. Focus arriving in the composer, by Tab, click-to-open or ⌥⌘Z, keeps a restored draft intact with the caret at its end (`ZeusComposer`, Q2 DES-1); a click inside the text keeps the caret where it was clicked.
- Focus ring: as CARDS.md §7 (a 1 px `palette.accent` line inside the button frame). The composer field shows focus with its frame turning `palette.accent`; the system ring is off.

## 9. Right-click on Zeus (CONTRACT §10.5)

A standard `NSMenu`, in this order:

1. **Talk to Zeus**: open the panel, composer focused. Shows the ⌥⌘Z key equivalent.
2. **Settings…** (⌘,)
3. separator
4. **Character ▸**: the 12 characters in roster order (`CharacterLibrary.characters`), with a ✓ on the current one, then a separator and any user characters.
5. **Size ▸**: Small / Medium / Large, with a ✓ on the current one.
6. separator
7. **Hide for 1 hour**
8. **Hide until tomorrow**: hidden until 08:00 local tomorrow, or until quiet hours end if they're set and end later.
9. separator
10. **Quit Zeus**

**While hidden**
- The menu bar item reads "Zeus · Hidden until 14:30" and offers **Show Zeus**, which cancels the hide.
- New cards still update the badge on the menu bar icon (a dot) and still deliver.
- The avatar doesn't reappear early, even for high priority. That's the user's explicit choice.

## 10. Delivery warning (CONTRACT §10.6)

**Marker:** as CARDS.md §5 (a red "!" marker at the avatar canvas's top-left). It shows only on the §10.6 conditions.

**Popover.** Clicking the marker opens a `.popover` (arrow edge toward the avatar) whose content is `ZeusWarningPopover`.

**Message templates**
- Undeliverable to a known session: "**N repl(y/ies)** couldn't reach **<client> (<cwd last component>)**. It disconnected **<relative time>** ago."
- No session at all: "**N repl(y/ies)** are waiting, but no assistant session is connected."
- Footnote: "They'll be sent automatically when it reconnects." (or "…when an assistant connects.")

**Actions**
- **The primary button** (default, Return) is whatever fixes the problem, passed as `primary:` (A4D-5):
  - **Retry Now** when Zeus can actually try again (exhausted retries to a connected assistant);
  - **Start Assistant** when the assistant Zeus runs is stopped or never started;
  - **Start New Conversation** when it can't resume its conversation;
  - **none** (`primary: nil`) when no button can help, e.g. no assistant is connected. Discard… is then the only button.
- **Retry Now** calls the P5 retry API. On success, close the popover and clear the marker. On failure, keep the popover open and replace the footnote with the error in `palette.destructive`.
- **Discard…** turns into **Discard Them** / **Keep** (Esc = Keep). Two steps, because discarding is irreversible. Confirming calls the discard API and closes the popover.

## 11. Activity indicator (CONTRACT §10.8, D15)

The human's ask: after sending, *see* that the agent got it and is on it. Render `ZeusTypingIndicator` as the **last row of the thread**, on the agent side, while `AgentMessaging.assistantActivity` is non-nil. Render: `docs/design/typing-d15.png` (`zeus-sprites typing`).

```swift
if let a = runtime.assistantActivity {
    ZeusTypingIndicator(phase(a.phase), agentName: a.agentName, detail: a.detail, progress: a.progress)
        .id("typing")                 // the auto-scroll target when the user is at the bottom
}
// phase(_:) maps AssistantActivity.Phase 1:1 onto ZeusTypingIndicator.Phase (.sent / .thinking / .working).
```

**Look.** It's a compact agent bubble, hugging its content. It holds three pixel dots (6 pt, 4 pt apart), then a one-line caption in the caption font and `secondaryText`, truncated at the tail. When the agent sends `progress`, a 6 pt pixel bar sits underneath with a percentage, and the bubble is at least 180 pt wide.

| Phase | Frame | Dots | Clock | Caption |
|---|---|---|---|---|
| `.sent` | flat panel-colored bubble with a light outline (no opacity) | `secondaryText`; one brightens at a time, no hop | 0.4 s (2.5 changes/s) | `detail`, else "Sent to <agent>" |
| `.thinking` | the agent bubble's light frame | gold (`title`); the lit dot hops 4 pt, then a beat of rest | 0.2 s (5 changes/s) | `detail` if any |
| `.working` | same | same | 0.2 s | `detail`, else "Working…" |

`.sent` is deliberately quieter: it only says "delivered". The step up to gold, hopping dots is the moment the agent visibly picks it up. The dots echo Zeus's own thinking emote (three squares above his head), so the panel and the avatar say the same thing.

**Motion and cost.**
- The dot cycle is a **Core Animation** keyframe animation (discrete, repeating, aligned to a fixed epoch) on a small layer-hosting view. It's committed once and runs in the render server, so the app does no work per step and the SwiftUI body re-evaluates only when phase, detail, progress or the environment change (D16). A `TimelineView` here re-laid out the whole panel 5× a second: about 9 points of app CPU.
- With `\.zeusAnimationsActive` false (the panel closed or occluded, the screen locked) or Reduce Motion on, it draws one still frame: all three dots lit, or all dim for `.sent`. There's no clock at all, so a hidden panel pays nothing.
- The progress bar is static and changes only when `progress` does. There's no marquee: the dots already are the indeterminate state.
- The row has a fixed height, so the hop never moves the thread. Phase and detail changes swap in place, without a transition.

**Placement and life cycle.**
- It always sits below the newest bubble, with the normal bubble spacing.
- It appears without animation, and it disappears in the same update that adds the agent's new bubble. The two never show together, and the thread doesn't jump.
- With several sessions there's one indicator (the runtime picks it). Add the `ZeusSessionLabel` above it only when the thread already shows session labels (§3).
- When the panel is closed, there's no bubble or peek. The avatar's `thinking`/`working` state (§7 rule 3b) carries it. Both read clearly at ×3: thought dots above the head with a hand to the chin, and a turning gear with a sparking bolt.

**`ZeusActivityRow`** (above the composer, from D5) is superseded by this row for agent activity. Keep at most one: A8 should drop the composer-side row when it adds the indicator. The component stays in ZeusDesign for other uses.

**Accessibility.** One element, labelled "Claude is thinking", "Sent to Claude", or "Claude is working, Drafting your Q3 talk, 40 percent". Don't post announcements for phase changes; the new bubble's announcement (§12) is the signal that matters.

## 12. Accessibility

- The thread is a list. Each bubble is one element: the label is "<Zeus | You>: <title>. <body>", and its option and attachment buttons are child elements.
- Session labels read "From Claude · Zeus" (the same text as the label, §3).
- Dividers are headers.
- When a new agent bubble arrives while the panel is open, post a VoiceOver announcement with the title, or the first sentence of the body.
- Everything above respects Reduce Motion (no scroll animation, static activity dots) and Reduce Transparency (opaque panel).

## 13. Acceptance checklist for A5

- [ ] The user never has to dismiss anything to type. The composer is focused on open, every time.
- [ ] Answering an old question by clicking works; ⌘N answers the newest.
- [ ] The reply chip appears only for a question that accepts text; ✕, ⌘K and Backspace clear it; a newer question re-arms it.
- [ ] The placeholder sits exactly on the caret: `ZeusComposer` is used, with no overlay placeholders anywhere in `Zeus/`.
- [ ] Scrolled up, new messages show "↓ N new" and never yank the view.
- [ ] The badge and `alert` clear as items become visible; `waiting` clears when the question is answered.
- [ ] Esc closes and returns focus to the previous app; ⌥⌘Z reopens with the draft intact.
- [ ] Session labels appear only with more than one session, and only where the session changes; same-folder sessions are told apart by ordinal (§3); muted cards keep their attachments; progress updates in place.
- [ ] The warning popover's Retry and Discard work, and Discard needs two steps.

---

## 14. Peek bubble (CONTRACT §10.7)

When a message arrives and the panel is **closed**, Zeus *says* it: a small speech bubble pops from him and the text types out while he talks. Nothing takes focus, nothing has to be dismissed, and the card is in the thread either way.

**References:**
- Component: `ZeusPeekBubble`, with timing in `ZeusPeekTiming` (`Packages/ZeusKit/Sources/ZeusDesign/ZeusPeekBubble.swift`).
- Render: `docs/design/peek-d8.png` (`zeus-sprites peek`).

### 14.1 When it shows

| Event | Bubble? |
|---|---|
| New agent card of kind `message`, `question` or `content` | **Yes** |
| `progress` card, `zeus_update_card`, status changes, `userMessage`, an expiry | No |
| Panel open | No: the thread shows it (§7) |
| Quiet hours, avatar hidden (§9), or macOS Focus/Do Not Disturb if detectable | No: only the badge and the menu bar dot |
| A new card while a bubble is showing | **Replace the content in place**: no exit/enter. Restart the typewriter, the talking and the auto-hide timer, and update "+N more". |

**"+N more"** is the number of *other* unseen, peek-eligible cards that arrived since the panel was last opened. The bubble always shows the **newest** one.

### 14.2 Anatomy and sizes

```
┌ Talk tomorrow ───────────── +2 more  ✕ ┐  title: .button, gold, 1 line · tag · close
│ Your talk on Q3 planning is tomorrow   │  body: .body, inline markdown,
│ at 10:00. Have you star…               │        3 lines, or 2 when there are buttons
│ 1 attachment                           │  caption, only if attachments
│ [Yes] [No] [Later] [Reply…]            │  small ZeusButtonStyle buttons
└─────────────────────▼──────────────────┘  tail → Zeus
```

- **Width:** 200–280 pt, fitting the content (`ZeusPeekTiming.minWidth`/`maxWidth`). The height fits the content.
- **Chrome:** `.zeusDialog(tail:, padding: Spacing.s)`, the same dialog as the panel but tighter.
- **High priority:** a **gold frame** that stays visible, like hover.
- **Title:** none means the body starts at the top; ✕ stays top-right.
- **Body:** truncated with "…" at the line limit. It's never scrollable: the full text is one click away.
- **Buttons** (`ZeusPeekBubble.layout`):
  - ≤3 options or actions: show them inline. Clicking one **answers the card in place**.
  - The card also takes text: add **Reply…**.
  - More than 3 options: show only **Reply…**.
  - Text-only question: show **Reply…**.
  - Plain message: no buttons.
- **"+N more":** a small secondary tag left of ✕. Clicking it opens the panel.
- **✕:** a pixel `ZeusGlyph(.close)` in `secondaryText` at rest (≥ 3:1), `text` on hover. Never fade it with opacity. It closes the bubble.

### 14.3 Placement and tail

Anchor to Zeus's sprite **art bounds** (the non-transparent part of the canvas, not the whole canvas, which has headroom for emotes). The tail tip sits **4 pt** from the art.

Try these positions in order and use the first that fits inside `visibleFrame` inset by 8 pt:
1. **Above** (`tail .bottom`): the bubble's bottom edge sits over Zeus. The tail offset is the avatar's anchor x in bubble coordinates, clamped to [16, width − 16].
2. **Beside**, on the side facing the screen's center (`tail .leading` when the bubble is to Zeus's right, `.trailing` when to his left). The tail offset is the y of Zeus's head center in bubble coordinates, clamped the same way.
3. **Below** (`tail .top`).

If none fits whole, use **above**, clamped to the screen; the tail keeps pointing at Zeus.

The bubble **follows drags** in the same frame as the avatar, and re-runs placement while it moves.

### 14.4 Typewriter and talking: Zeus says it

- **The bubble types** at 40 characters/s.
  - Long text types faster rather than longer: a reveal never takes more than **2.4 s**.
  - Only the visible ~100 characters are typed (`ZeusPeekTiming.typedLength`), and markdown syntax is never typed.
  - The bubble is laid out at its final size from the first frame (the full text is laid out invisibly), so it never grows while typing.
  - Use `reveal: .typing(start:)` with the time the bubble appears.
- **Zeus talks for exactly as long.** Set the avatar's transient state (CONTRACT §7, rule 1) to `talking` for `ZeusPeekTiming.talkingDuration(length:reduceMotion:)`: the typing time plus 0.25 s, so the mouth closes on the last word.
  - If the card has a `mood`, show it for the rest of the transient window, which is `max(2.5 s, talking duration)`.
  - A replacement (§14.1) restarts both clocks.
- **Reduce Motion, or the typewriter setting off:** the text appears at once, and Zeus still talks for **1.2 s**. Talking is frame animation, not movement, so it's fine under Reduce Motion. Use `talkingDuration(length:reduceMotion: true)` whenever the text isn't typing.
- No sound. Sound effects are a phase-2 setting.

### 14.5 Enter and exit

- **Enter:** `AnyTransition.zeusPeek(reduceMotion:edge:)`. The bubble rises 4 pt toward Zeus's opposite side from its tail and fades in over 160 ms (ease-out). Offsets are whole points.
- **Exit:** fade out over 120 ms, on auto-hide, ✕ or any interaction.
- **Reduce Motion:** opacity only, both ways.
- A replacement doesn't animate the bubble, only its text, by typing again.

### 14.6 Interaction

| Action | Result | Marks seen |
|---|---|---|
| Click the body or title | Open the panel scrolled to this card, composer focused; hide the bubble | this card |
| **⌥⌘Z** while a bubble shows | same as clicking the body | this card |
| Option button | Answer the card (CardStore → `responseHandler`). The button shows ✓ for 0.6 s, then the bubble exits. The answer appears in the thread as usual. | this card |
| **Reply…** | Open the panel scrolled to this card with the **reply chip set to it** and the composer focused | this card |
| **+N more** | Open the panel scrolled to the **oldest** unseen card | none yet: the panel's rules apply (§7) |
| **✕** | Hide the bubble | this card |
| Nothing | Auto-hide (§14.7) | none: the badge and `alert` remain (CONTRACT §10.7) |

The bubble never takes keyboard focus. Its panel is a non-activating `NSPanel` (`.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`) whose hosting view accepts first mouse, so the first click on a button acts immediately, even while another app is active.

### 14.7 Auto-hide and hover

- **Delay:** `ZeusPeekTiming.autoHideDelay(words:highPriority:)` = `clamp(4 + words/4, 6, 15)` s, where words come from `wordCount(title:body:)`. It counts from the **end of typing**, so the reading time isn't eaten by the typewriter.
- **High priority:** `nil`, so the bubble stays until the user interacts.
- **Hover** pauses the timer. The frame warms to the accent and ✕ darkens to the text color (both built in). On exit, the timer resumes with `max(remaining, 2 s)` (`minimumAfterHover`).
- **Panel opening** (by any route) hides the bubble immediately, without animation.

### 14.8 Accessibility

- When a bubble appears, post the same VoiceOver announcement as a new message in the open panel (§12). The bubble's label is "Zeus says: <title>. <body>".
- The bubble's buttons are reachable with VoiceOver even though the panel never becomes key.
- Reduce Motion: §14.4 and §14.5. Reduce Transparency: an opaque bubble (built into `.zeusDialog`).

### 14.9 Acceptance checklist for A5c

- [ ] With the panel closed, a new message, question or content card pops a bubble; progress, status and updates never do.
- [ ] Focus never leaves the app you're typing in. Clicking an option works on the first click.
- [ ] Zeus's mouth moves for exactly as long as the text types (and 1.2 s under Reduce Motion).
- [ ] The bubble keeps its size while typing; long text truncates with "…", and buttons cut the body to 2 lines.
- [ ] A second arrival replaces the content in place with "+1 more", not a second bubble.
- [ ] Hover pauses auto-hide; high priority stays and is gold; ✕ closes it.
- [ ] Ignored cards stay unseen (badge and `alert`); any interaction marks the shown card seen.
- [ ] Above, beside or below placement works at every screen edge and corner, and the bubble follows drags.
- [ ] No bubble during quiet hours or while hidden.
- [ ] With **Play a sound when Zeus pops up** on, the sound plays once as the bubble appears (§14.10), never for a replaced bubble, and never more than once in 4 s.

### 14.10 Sound (N2)

An optional sound when the bubble pops up: Settings › General › Sounds › **Play a sound when Zeus pops up**. It's **off by default**: the user asked for it as an option, Zeus already makes no noise unless asked (the typewriter blip is off by default too), and a new sound arriving with an automatic update would surprise people.

| When | Sound? |
|---|---|
| The bubble appears (hidden → shown), for any card that pops it (§14.1), questions included | **Yes**, once |
| A new card replaces a bubble that's already showing | No: same pop-up |
| Within 4 s of the last sound (`PopupSoundGate.minimumInterval`) | No |
| Anything that stops the bubble (§14.1): panel open, so the user may be typing there; hidden or snoozed; quiet hours; a macOS Focus Zeus can see | No |

- **Sounds:** **Zeus chime** (default) or the macOS sounds Glass, Ping, Pop and Tink. Choosing one, or turning the toggle on, plays it as a preview.
- **Zeus chime:** three quick 25%-duty square-wave notes, B5 → E6 → B6 (45, 45 and 160 ms, the last one ringing out), at 20% of full scale. It's generated in code (`ZeusChime`), not a recording.
- **Volume:** System Sound Services, so it follows the Mac's alert volume and output device (System Settings › Sound), like any alert. Zeus has no volume control of its own.
- **Accessibility:** the sound adds to the VoiceOver announcement (§14.8); it never replaces it. Reduce Motion doesn't silence it: it's a sound, not motion.

## 15. Status strip (TB1)

One line between the thread and the composer, always visible. It says why Zeus shows "?" or "!", jumps to the thing that put it there, and holds the panel's quick actions. Component: `ZeusStatusStrip` over a plain `ZeusStatusStripModel` (`ZeusStatusStrip.swift`); the app maps its state to the model with a pure function and uses the model's factories, so all copy lives in ZeusDesign.

### 15.1 Layout

```
│ ? Waiting for your answer · Go to question · Skip      ▣ ⊞ ▥ ✲ │  24 pt
├────────────────────────────────────────────────────────────────┤  1 px, palette.divider
```

- **Height** 24 pt, **no rule above**, a **1-px rule below** in `palette.divider` (the theme's `divider`, by default secondary text at 75 %, at least 3:1 on the panel; D18). The strip replaces the 2-px rule that sat between the thread and the composer.
- **Type:** `.caption` in the pixel font, one line.
- **Colors** come from the palette only, so every bundled theme works:
  - glyph and links: `title`
  - sentence: `text`
  - idle and quiet hours: `secondaryText`
  - "·" separators: `secondaryText`
  - icons: `secondaryText` at rest, `title` on hover or focus, 50 % when disabled.
- **Left:** glyph, sentence, "·", link, then "·" and **Skip** when a question waits. The sentence and its link are **one button** (the jump), with a 22-pt target and a 1-px `focusRing` underline when focused, like the thread's notice lines (§3).
- **Too narrow:** when the full line doesn't fit beside the buttons, the link words drop and the sentence itself takes the link color ("? Waiting for your answer · Skip"). Only after that does the sentence truncate with "…". Skip never truncates.
- **Right:** up to four 12-px pixel icons in 22-pt targets, 2 pt apart, each with a tooltip and the same accessibility label.

### 15.2 States and copy

The sentence always matches the avatar, so the app picks the row in CONTRACT §7's order: unseen, then activity, then an open question, then quiet hours, then idle. Blocked and delivery problems aren't in §7; the app ranks them (TB1-A).

| Avatar state | Factory | Strip | Jump |
|---|---|---|---|
| waiting, 1 question | `.waiting(questions: 1)` | `? Waiting for your answer · Go to question · Skip` | scroll to the question, focus its first option (or Reply…), make it the reply target |
| waiting, several | `.waiting(questions: 2)` | `? 2 questions · Go to oldest · Skip` | the oldest; each further click moves to the next |
| waiting on a Terminal prompt card | `.waiting(questions:, skippable: false)` | no Skip | as above |
| alert, unseen | `.unread(1)` / `.unread(3)` | `! Unread · Show` / `! 3 unread · Show` | the first unseen message |
| blocked (managed) | `.blocked(mirrored: false)` | `! Waiting for you in Terminal · Open` | opens Terminal |
| blocked, prompt mirrored | `.blocked(mirrored: true)` | `! Waiting for your answer · Go to prompt` | the prompt card |
| thinking / working | `.activity(text)` | the activity row's text, e.g. `Claude is working on tests`; the sentence is the link | the bottom |
| delivery problem | `.notDelivered()` | `Message not delivered · Show` | the failed bubble |
| sleeping (quiet hours) | `.quiet(until: "8:00")` | `Quiet until 8:00`, secondary | none |
| idle | `.idle()` | `Idle`, secondary | none |

**Skip** marks the oldest open question skipped: the card closes with "Skipped" under it and the assistant is told (CONTRACT §5, TB1-P). It never appears for the agent's own Terminal prompts; Zeus never answers or dismisses those.

VoiceOver reads the glyph as a word: "Question. Waiting for your answer. Go to question", "Alert. 3 unread. Show". The strip is a container labelled "Status".

### 15.3 Buttons

| Icon | Tooltip and label | Shown when | Does |
|---|---|---|---|
| ▣ window with `>_` | Open in Terminal | there's a terminal target: a managed session, or a tmux pane in Connect your own | opens it |
| ⊞ speech bubble with + | Start New Conversation… | managed session only | today's `startNewManagedConversation`, with its confirmation |
| ▥ trash can | Clear Conversation… | always; disabled when the thread is empty | today's confirmation |
| ✲ gear | Assistant Settings… | always | Settings › Assistant |

`ZeusStatusStripModel.buttons(hasTerminal:isManaged:canClear:)` builds the list in this order.

### 15.4 Keys and the avatar

- **⌘J** is the jump. **⌘⇧J** is Skip, only while a question is waiting.
- **Clicking Zeus** while "?" shows opens the panel scrolled to that question, not to the bottom. While "!" shows, it opens at the first unseen message.
- **Reduce Motion:** jumps land without an animated scroll.

### 15.5 References

`scripts/design-harness/render.sh "statusStrip()"` renders `build/q2-renders/status-strip-<theme>__{light,dark}-pixel.png`: every state, in each of the 7 bundled themes, light and dark.

## 16. Learn from me in the thread (LM2)

The full copy and the reasons behind it are in `PRIVACY.md` §6–7. This section covers what the conversation itself shows.

- **Rule lines** are notice lines (§3, kind `learning`): secondary text, one action link, no peek, no sound, never counted as unread.
  - "New rule: <sentence> · Review"
  - "I'd have sent “<text>” to <where> · OK next time?" (one action; after it: "OK. I'll do that from now on. · Undo")
  - "Held 2 messages for your rule “<sentence>” · Show"
  - "Retired a rule you kept skipping: “<sentence>” · Review"
  - Several new rules from one reflection collapse to "3 new rules · Review".
  - Render: `lm2/lm2-thread-lines__*.png`.
- **Held messages:** while a passive rule holds non-urgent deliveries, cards still land in the thread, but there's no peek and no sound, and the badge counts them. `high` priority still peeks. The status strip (§15) doesn't change for held cards. Its sentence stays whatever CONTRACT §7 gives.
- **Drop on Zeus:**
  - The avatar shows `alert` and a peek-style "Drop to attach" while something is dragged over it.
  - The panel opens with the composer focused and the dropped items as removable chips. Send works with no text.
  - Nothing dropped is journalled. It goes to the assistant only when you press Send, like any attachment.
- **Reflection** is never shown as a user message. The ledger in What Zeus Kept lists it as "Day reflection". If the agent replies in the thread, the reply is an ordinary agent card.
- **Ask About This (Phase B):** "Ask About This" (Zeus menu, or the Talk shortcut with Shift added) opens the conversation with context chips already attached: Window, Selection, Page and Picture. Each is removable, and the full copy is in `PRIVACY.md` §9.6. The chips use the attachment-chip style above the composer, and Send works with chips alone. Render: `lm2/lm2b-ask-chips__*.png`.
- **Typing (Phase C):** Level 4 adds nothing to the thread or the avatar. While a password field is active, the Zeus menu's status section shows the disabled line "Private input: Zeus isn't noting typing" (`PRIVACY.md` §10.5).
