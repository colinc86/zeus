# Conversation Panel: Visual and Interaction Spec (v1)

**Implements:** CONTRACT §10 (including §10.7, the peek bubble, in §14). **Audience:** appdev (A5). **Supersedes:** the card-stack parts of CARDS.md (§1 Anatomy, §2, §3, §5 stack/pager, §6). CARDS.md still governs the badge, the delivery-warning marker, the dialog tail and the do/don'ts.

**References:**
- Rendered: `docs/design/conversation-d5.png`
- Live: the `#Preview("Conversation")` in `ZeusConversationGallery.swift`
- Components: `Packages/ZeusKit/Sources/ZeusDesign/ZeusConversation.swift`

**Colors:** read `@Environment(\.zeusPalette)`. It follows the color scheme and Increase Contrast (`ZeusPalette.lightHighContrast` / `darkHighContrast`, AAA text). Never fade text with `.opacity`; use `secondaryText` / `mutedText`. Symbols the pixel font lacks (✓ ✕ ↩ ◀ ▶ ↑) are `ZeusGlyph`s, and `ZeusFonts.pixelFontMissingGlyphs(in:)` checks any new UI string.

**Type:** all text uses the `.zeusFont(_:)` roles. With the default pixel font, Departure Mono (D10), that's **16.5 pt for titles and 11 pt for everything else** at the Default text size, on the font's 11 px/em grid so it renders crisp; the user's text size (§19) moves every role in whole grid steps. SF Mono is the user's alternative. Departure Mono has one weight and no italic, so in the pixel font markdown **bold** renders in the gold title color instead of a bold face and *italic* in the secondary color, and inline `code` gets a subtle tint (both fonts). Block markdown (F9) renders in the same single `Text`: headings as bold lines, `•`/`–`/`1.` list markers with nested indents (one newline between items), `▌` quote bars in the secondary color, fenced code as a tinted block padded to one width with the language tag dropped, tables as `│` rows, and rules as a short `─` line. There's a blank line between other blocks. Paragraph line breaks are kept. Use `ZeusMarkdown.spokenText(_:)` for accessibility labels; it drops the decorations. Render bodies with `ZeusMarkdown.attributed(_:choice:palette:)` or `ZeusMarkdownText`.

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
 │            [↑ 3 unread ×] [↑ ? Question]  │ ← ZeusJumpPillCluster, top (only when they're above, §20)
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
 │                 [↓ 2 new]                │ ← ZeusJumpPillCluster, bottom (only when scrolled up, §20)
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
| `message` | agent | `ZeusBubbleHeader(title, time)` if `title`, then the body, then one attachment chip per attachment (§18) |
| `question`, open | agent | header, body, `ZeusOptionButtons(.open(shortcuts:))`. Shortcuts are only on the newest open question that has options (§8). |
| `question`, answered | agent | header, body, `ZeusOptionButtons(.answered(optionID:))` showing only "✓ <label>", or nothing for a text answer. **Plus** a user bubble with the answer, placed **chronologically at the time of answering** (amended in D12: it used to say "right after the question card"). When the entry just before it isn't its question, add a caption above it: "↩ <question title>" (secondaryText, `.caption`, right-aligned). |
| `content` | agent | header, body, one attachment chip per attachment (§18), then actions as `ZeusOptionButtons` (same open/answered rules as a question) |
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
- **A new item arrives while scrolled up:** don't move. The latest pill (§20) shows bottom-center over the thread: "↓ 2 new".
  - Clicking it or pressing ⌘↓ scrolls to the bottom.
  - The count is the number of unseen items below the viewport.
  - Progress updates never count.
- **Unseen items above the viewport** (older messages the user never scrolled past, kept in `seenIDs`) get the unread pill at the top; an open question that is off-screen gets the question pill on its side. §20 has the rules.
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
| ⌘↓ | panel | Jump to latest, the same jump as the latest pill (§20); the key works whether or not a pill is shown |
| ⌘R | panel | Rate the focused assistant message, or the newest message the assistant sent on its own: opens its rating row (§17). Esc closes the row only. |
| Tab / ⇧Tab | panel | Native key-view traversal; Zeus doesn't intercept Tab. Focus moves in reading order through every control in the loaded thread, then the composer, and wraps. See the note below. |
| Space | a focused button | Activate it (standard) |
| Esc | panel | Close the panel and return focus. If the warning popover is open, close only the popover. |
| ⌘, | panel | Settings |
| Esc, ⌘[, ⌘O, ⌘⇧R, ⌃⌘F, ⌘F, ⌃⌘←/→, ⌘⇧', ⌥⌘U | document viewer | §21.10 |

Notes:
- Register ⌥⌘Z with Carbon `RegisterEventHotKey`. It needs no Accessibility permission. If registration fails because another app owns the combination, show "⌥⌘Z is in use; choose another" in Settings → Agent.
- Tab order: "Load earlier messages", then oldest to newest, each bubble's controls: open option buttons, the Welcome card's buttons, Retry on a failed send, and each attachment chip, then its "More" when the summary is clipped (§18). The composer comes last. Answered, closed and muted bubbles have no stops. Every thread control is `.focusable()` with a unique focus identity (entry + control). Then Tab reaches it without the system's Keyboard Navigation setting, and two cards that reuse an option ID never share a stop.
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

- The thread is a list. Each bubble is one element: the label is "<Zeus | You>: <title>. <body>", and its option buttons and attachment chips are child elements (chip labels and actions in §18.5).
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
│ ▢ Q3 Planning.key                      │  attachment chip, only if attachments (§18.4):
│   12 slides from your planning notes.  │  name, 1 line of summary · "and 1 more" caption if several
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
- **Attachments:** the first one as a chip (§18.4), never the old "1 attachment" caption; `ZeusPeekBubble(attachment:)` takes the app's chip view.
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

> **Status:**
> - **Phase A (ships in Phase A):** rule lines, held messages, drop on Zeus and reflection.
> - **Shipped:** Ask About This (LM2-B-A), Typing (LM2-C-A) and the Phase D lines (LM2-D-A). The acted line ships as "Did: … · Undo".

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
- **Phase D lines** (quiet notice lines, `PRIVACY.md` §11):
  - "Looked at your journal: Tue 14:00–15:30 · View"
  - The acting-rule shadow lines ("I'd have sent / posted / drafted / changed / bought / booked … · OK next time?")
  - The acted lines ("Sent … · Undo" / "· Not again")
  - "Retired a rule …"

  None peeks, sounds or counts as unread. Several journal looks within 10 minutes collapse into one line. The assistant's reply to an Undo is an ordinary agent card.

## 17. Rating what the assistant tells you (FB1)

> **Status: building (FB1-A on FB1-P's seams; copy here is final).** User decision 2026-10-16: a subtle "⋯" on the assistant's own messages offers More like this / Neutral / Stop these, applied to the message's *kind*. Storage, delivery and the folder file are in `PRIVACY.md` §13.

The assistant labels each message it sends on its own with `about`, a short name for its kind ("On-call reminder"). The user rates the kind, not the message. Zeus decides what counts as a reply (`CardOrigin.reply`: posted while a response row for the user's own message or answer was open); replies never get a menu. Nothing here peeks, sounds, badges or counts as unread.

### 17.1 The "⋯" affordance

- **Where:** inside the bubble, at its top-trailing corner, on the header line beside the time: `ZeusGlyph(.more)` (three 2 × 2 px squares) in a 22 pt square target, `Spacing.s` left of the frame. The time moves 22 pt + `Spacing.s` to the left on every unprompted bubble, rated or not, so nothing shifts on hover. An unprompted bubble without a title shows the header anyway, with the time alone, so the slot has a line to sit on.
- **Which bubbles:** `message`, `question` and `content` cards with `CardOrigin.unprompted`, high priority included. Never replies, progress cards, Zeus's own cards (Welcome, blocked), notice lines or user bubbles.
- **Colors** (palette tokens only, so every theme works; never opacity): drawn in `secondaryText` while the pointer is over the bubble or focus is inside it; `title` while the glyph itself is hovered or focused, and while its row is open. At rest it isn't drawn, with one exception for discoverability: until a rating row has been opened once on this Mac, the newest unprompted bubble draws it at rest in `secondaryText`.
- **Peek bubble:** the same glyph left of "+N more" and ✕, drawn while the peek is hovered (hover already pauses auto-hide). Clicking it opens the panel scrolled to this card with its rating row open; the peek is too small for the row.
- **Tooltip and label:** "Rate this kind of message (⌘R)". It's a first-click target (CONTRACT §10.1).
- **Rated bubbles** keep the glyph; clicking it reopens the row with the current choice marked (17.2).

### 17.2 The inline row

Clicking ⋯ (or ⌘R) opens the row inside the bubble, under everything else in it, after a 1 px `divider` line with `Spacing.s` above and below. No popover.

```
┌ On-call tonight ──────────── 21:40  ⋯ ┐
│ You're on call from 22:00. The pager   │
│ is set to loud.                        │
│ ─────────────────────────────────────  │
│ [More like this] [Neutral] [Stop these]  │  small secondary ZeusButtonStyle; wraps to two lines when they don't fit
│ For all “On-call reminders” · Edit · Just this one │  caption, secondaryText; links in title
└────────────────────────────────────────┘
```

- **The three choices**, left to right: "More like this", "Neutral", "Stop these". Words only: a 7-px thumb doesn't read on the text grid (the FB1-A renders proved it), and the words say it. Neutral's tooltip and VoiceOver hint: "Only when I need to know". Rules that act are elsewhere; these three never do anything to the message itself.
- **The kind line:** "For all “<label>” · Edit · Just this one", with the "·" separators in `secondaryText` as the status strip draws them, so the links don't run together. The label is the card's `about`; without one it's the card's title, else the first 30 characters of the body with "…". Edit turns the line into a one-line field holding the label (1–60 characters, Return saves, Esc cancels, blank reverts). "Just this one" flips the line to "For this message only · All of this kind", and the three choices then rate only this message.
- **Choosing** collapses the row to one caption line in the same place (`secondaryText`, Undo in `title`), which stays as long as the rating exists:

| Choice | For the kind | Just this one |
|---|---|---|
| More like this | "More like this: On-call reminders · Undo" | "More like this one · Undo" |
| Neutral | "Only when I need to know: On-call reminders · Undo" | "Only when I need to know, this one · Undo" |
| Stop these | "Stopped: On-call reminders · Undo" | "Not this one · Undo" |

- **Undo** restores whatever was there before this choice (FB1-P's snapshot undo, kept across relaunch): nothing, so the line goes and the bubble is back to ⋯, or the previous choice, so the line changes to it. "· Undo" shows only while `ratingUndo(id)` is valid; once a later change (here, in Settings, or a correction) supersedes it, the line stays as the record without Undo, and removal is through the row's "Remove rating". Never show an Undo that does nothing.
- **Reopening** a rated bubble's row shows the current choice as a "✓ Stop these" chip (the `.answered` style) with the other two live; picking another changes the rating in place, and the kind line gains "· Remove rating". A rating changed or removed in Settings updates the bubble's line.
- **Keyboard:** ⌘R opens the row on the focused bubble, or on the newest unprompted bubble when nothing in the thread is focused, and focuses "More like this". Tab and the arrow keys move through the choices and the links; Return activates; Esc closes the row and nothing else; ⌘R again closes it. ⌘1–9 keep answering questions.
- **VoiceOver:** the bubble gains custom actions "Rate: more like this", "Rate: only when I need to know", "Rate: stop these", "Rate this message only" and "Edit the kind label". The collapsed line reads as written, with "Undo" as its button.

### 17.3 Muted messages

A new unprompted card whose kind is stopped is held: it lands in the thread at its time as one collapsed notice line, never deleted.

- **Collapsed:** "Muted: On-call reminder · Show", using the card's own `about` (or the matched kind's label when it has none). Notice style (§16): `secondaryText`, no peek, no sound, no badge, not unread; the status strip ignores it.
- **Show** expands it under the line, which stays and reads "Muted: On-call reminder · Hide" (the §4.2 View/Hide disclosure): the full bubble in the muted style (§4, `muted: true`), options still live, no ⋯ and no rating line of its own (it was held by a rating on another card; only the card that was rated carries one), with a caption under it:
  - exact match: "Stopped kind: On-call reminders · Not this kind · Change rating"
  - look-alike: "Looks like On-call reminders · Not this kind · Change rating"
  - The reason carries a tooltip with the decision: "Matched by the on-device model, 0.82" (engine and score from FB1-P), or "Same label".
- **Not this kind** unmutes this card (normal bubble, with ⋯) and records the correction. Its caption becomes "Shown. Zeus won't count this as On-call reminders · Undo", with Undo on the same rule as 17.2: shown only while the correction's undo is still valid.
- **Change rating** opens the rating row on this bubble with the matched kind's label filled in.
- **End of day:** once a day, when quiet hours start (or at 21:00 when none are set), if anything was muted that day: a notice line "3 muted messages today · Show" ("1 muted message today · Show"). Show expands every muted row of the day and scrolls to the first. Expanded rows stay expanded.
- Muted cards are never high-priority gold, even if marked `priority: high`: the hold wins.

### 17.4 Settings › Rules › "What you hear about"

The first section of the Rules pane, above the "New rules" dial and followed by a `SettingsDivider`: ratings don't depend on Learn from me, so they come first and are always there. `settingsTitle` "What you hear about" with a count ("What you hear about · 6"; no count while empty). While something is muted today, a line under the title: "Muted today: 3 · Show" (opens the panel with them shown).

Rows are grouped under `settingsBody` subheads "More like this", "Need-to-know" and "Stopped"; empty groups are hidden.

| Part | Content |
|---|---|
| title | the kind label |
| caption 1 | the example, quoted and redacted, cut at 80 characters with "…" |
| caption 2 | "Last matched Tue 14:02", or "Not seen since you rated it" |
| switcher | `SettingsSegments` with three stops "More", "Neutral", "Stop"; VoiceOver "More like this", "Only when I need to know", "Stop these" |
| buttons | "Edit Label" (inline field, as 17.2) and "Remove" (no confirmation; the bubble's line goes with it) |

- **Empty state:** "Nothing rated yet. Hover a message your assistant sent on its own and click ⋯ to say whether you want more of that kind, none, or only when you need to know."
- **Footer caption**, once, after the last group: "Your assistant gets each rating as a message and keeps the list in its folder as Zeus/preferences.md. Stopped kinds are held by Zeus even if your assistant still sends them."
- "Just this one" ratings aren't rows; they're in What Zeus Kept (`PRIVACY.md` §13).

### 17.5 The suggestion line

When FB1-P exposes a `RatingSuggestion` (five quiet signals in seven days for one unrated kind): one notice line, once per kind, "Getting a lot of On-call reminders · Rate them · Not now". "Rate them" scrolls to the newest unprompted card of that kind and opens its rating row; "Not now" dismisses it for good. Two actions, so it fits `ThreadNotice` (primary and secondary) as it is; the four-button draft is dropped.

### 17.6 Renders

`build/fb1-renders/` (FB1-A): the glyph at rest, hovered and open; the row and each collapsed line; a muted row collapsed and expanded, both reasons; the Settings section with all three groups and empty; the suggestion line. Light and dark, both fonts, and the row in every bundled theme.

## 18. Attachment chips (AT1)

> **Status: building (AT1-A, on AT1-P's `summary`).** User decision 2026-10-16: "hey, look at this" plus a file isn't a message. Every file or folder attachment now carries a `summary` the assistant wrote (1–3 sentences, CONTRACT §4), the message text gives the takeaway, and the attachment itself sits quietly under the body: a chip, not a pair of buttons. Nothing in this section is a filled button; the chip must read as *less* prominent than the message text.

### 18.1 Anatomy

```
Here's the first draft. Slides 7–9 need your numbers.      body, as before
┌───────────────────────────────────────────────┐
│ ▢ Q3 Planning.key                          ⌕  │  icon · name (.body, text, 1 line, middle-truncated) · reveal icon (hover/focus only)
│   12 slides built from your planning notes;   │  summary (.caption, secondaryText, 2 lines)
│   the budget slides are placeholders.         │
│   More                                        │  only when the summary is clipped
└───────────────────────────────────────────────┘
```

- **One chip per attachment**, full bubble width, stacked with `Spacing.xs` between them, after the body and before any options or actions. `zeus_present` actions stay `ZeusOptionButtons`; its attachments are chips.
- **Chrome:** the quiet well the old row used: `palette.field` at 55% fill with a 1-px `fieldBorder` frame (`PixelFrame(outline: fieldBorder, frame: nil, steps: 1)`), padding `Spacing.xs + pixel`. Hover: the fill goes to full `palette.field`. Focus: the frame becomes `palette.focusRing`, as a field does. No outline change on press; the click is the whole chip.
- **Icon:** the kind's SF Symbol (`ZeusAttachmentRow.symbol(for:)`: doc, folder, link) at 11 pt semibold, the size the composer's draft chip uses, in `secondaryText` at rest and `title` while the chip is hovered or focused. Width 14, top-aligned with the name.
- **Name:** `attachment.label`, `.body` in `palette.text`, one line, `truncationMode(.middle)`. Template v4 makes the label the *name* of the thing ("Q3 Planning.key", "Speaker notes"), not a verb ("Open Keynote draft"); old cards keep whatever label they have.
- **Summary:** `attachment.summary`, `.caption` in `secondaryText`, under the name, indented to the name's leading edge, `lineLimit(2)` and "…" at the clip. A card without a summary (legacy, or a `url`) is a one-line chip: icon and name only, no empty line reserved.
- **More / Less:** only when the summary needs more than two lines (measure: lay the full text out hidden and compare heights, or `ViewThatFits`). A plain-style text button "More" in `palette.title`, `.caption`, on its own line under the summary, left-aligned with it. Click: the summary expands in place to its full height and the button reads "Less"; click again collapses. Expansion is per chip, not persisted, and never opens the attachment. Tooltip none. VoiceOver "Show the full summary" / "Show less".
- **Location:** the path caption ("~/Documents/Talks") leaves the resting chip. It is the chip's tooltip and is one Copy Path away (§18.3).

### 18.2 Click, hover, reveal

- **Click anywhere on the chip = Open**: a file or folder opens in the document viewer (§21); a link opens in the browser; apps, scripts, packages, aliases and executables are shown in Finder instead (`AttachmentTarget.action(for:)` decides) and the safety caption appears under the bubble ("Zeus shows apps and scripts in Finder instead of opening them.", `secondaryText`); folders open in Finder; links open in the browser. It is a first-click target: the panel needn't be key. The click-time errors stay: "This attachment has an invalid target." and "Could not open <name>." (`palette.destructive`, under the bubble).
- **Tooltip** on the chip: the location (`AttachmentTarget.locationCaption`, the folder in `~` form) for files and folders, the host for links; for a reveal-only target the safety caption instead.
- **Reveal icon:** `magnifyingglass` at 11 pt, in a 20×20 target at the trailing end of the name line. The slot is always reserved so the name's truncation never shifts; the icon is drawn only while the chip is hovered or focused, `secondaryText`, and `title` while the icon itself is hovered or focused. Click: Show in Finder (`reveal: true`), without opening. Tooltip "Show in Finder". Not shown for links, for reveal-only targets (the chip's own click already reveals) or when the file is missing.
- **Missing file or folder** (`url(for:)` resolves but nothing is there when the chip appears, re-checked on click): a third line "Not found" in `secondaryText` under the summary (or under the name when there is no summary); the name goes `mutedText`; no reveal icon. Click: Show in Finder of the nearest existing parent folder, so the user can see where it was; tooltip "Zeus will show the folder it was in." Copy Path still works.
- **Invalid target** (`url(for:)` is nil: a relative path, a non-http link): the name in `mutedText`, the line "Can't be opened" in `secondaryText`, nothing on click, no reveal icon; Copy Path / Copy Link only.
- **Muted bubbles** (§4, dismissed or expired): chips stay live, in the muted bubble's colors (`mutedText` for name and summary); the reveal icon still appears on hover.

### 18.3 Context menu

Right-click or Control-click on the chip (also the Menu key while focused):

| Target | Items, in order |
|---|---|
| file, folder | **Open**, Show in Finder, Copy Path |
| reveal-only (app, script…) | Show in Finder, Copy Path |
| missing | Show in Finder (the parent folder), Copy Path |
| invalid | Copy Path |
| `url` | **Open**, Copy Link |

Copy Path puts the expanded absolute path on the pasteboard (`~` resolved, symlinks not resolved); Copy Link the URL as given. No confirmation and no caption.

### 18.4 Peek bubble

The peek shows the card's **first** attachment as a chip in place of the old "1 attachment" caption: icon, name on one line, summary on **one** line ("…"), no reveal icon, no More, no context menu. Clicking the chip opens the panel straight into the viewer for that attachment (§21.1); a link opens in the browser and a reveal-only target reveals, as §18.2, without opening the panel. When the card has more, a caption under the chip in `secondaryText`: "and 1 more attachment" / "and 2 more attachments"; clicking it opens the panel at the card. The body keeps the limit CONTRACT §10.7 sets (up to 6 lines, then "…" and "More"); the chip never shortens it, and the §14.2 anatomy's older 3/2-line figures do not apply (A9 superseded them). Legacy or link attachments without a summary are a one-line chip.

### 18.5 Keyboard and accessibility

- The chip is one focus stop in the §8 Tab order (where Reveal then Open used to be two). Return or Space opens, as a click does (the viewer for files and folders, §21). ⌘Return shows in Finder when that item exists. The "More" button is the next stop when present; Return toggles it.
- VoiceOver: the chip is one element, label "<kind>: <name>, <summary>" ("File: Q3 Planning.key, 12 slides built from your planning notes."), with "Not found" or "Can't be opened" appended in those states. Custom actions: "Open" (or "Show in Finder" when that is what the click does), "Show in Finder", "Copy Path" or "Copy Link", and "Show the full summary" while the summary is clipped. The reveal icon is `accessibilityHidden`: its action is in the chip.
- Reduce Motion: the More/Less expansion is instant.

### 18.6 Renders

`at1/at1-chip-rest__*`, `-hover`, `-focused`, `-expanded`, `-missing`, `-link`, `-legacy` (no summary), `-present` (chips above actions), `-peek` (one chip and "and 1 more attachment"), each in light and dark and both fonts, from `build/at1-renders/`.

## 19. Text size (FS1)

> **Status: building (FS1, appdev).** User request 2026-10-16: a way to set the font size. Four presets, not a slider: the pixel font is crisp only in whole 5.5 pt steps, so a slider would mostly produce blur.

### 19.1 Setting and copy

Settings › Appearance, directly under "Conversation font": `SettingsSegments(label: "Text size")` with **Small · Default · Large · Larger** (`ZeusFontScale`, persisted as `appearance.fontScale`, default Default). Accessibility labels "Small text", "Default text", "Large text", "Larger text". One caption under it:

> Applies to the conversation, the peek bubble and the status line. Settings and menus keep the system size. The pixel font grows in whole steps, so two neighbouring sizes can look the same.

The scope is everything drawn with `.zeusFont(_:)` under a root that injects `\.zeusFontScale`: the thread, the composer, the status strip, the peek bubble, attachment and context chips, rating rows, notice lines, the delivery warning. Settings, menus and the component galleries' chrome keep the system size (`.default`).

### 19.2 Sizes per role

Pixel font (Departure Mono), in points on the 5.5 pt grid (`ZeusTextRole.pixelGridStep`). Body can't go below 11 and stay readable, so Small shrinks the titles; Large lifts text, buttons and titles; Larger also lifts the captions (times, status line, summaries, rating lines), the step that matters for reading at a distance.

| Role | Small | Default | Large | Larger |
|---|---|---|---|---|
| `.title` | 11 | 16.5 | 22 | 22 |
| `.body` | 11 | 11 | 16.5 | 16.5 |
| `.caption` | 11 | 11 | 11 | 16.5 |
| `.button` | 11 | 11 | 16.5 | 16.5 |
| `.badge` | 11 | 11 | 11 | 11 |

SF Mono: the Default size times the preset's factor (0.85 · 1.0 · 1.18 · 1.36), rounded to the nearest 0.5 pt, which gives:

| Role | Small | Default | Large | Larger |
|---|---|---|---|---|
| `.title` | 12 | 14 | 16.5 | 19 |
| `.body` | 10.5 | 12.5 | 15 | 17 |
| `.caption` | 9.5 | 11 | 13 | 15 |
| `.button` | 10 | 12 | 14 | 16.5 |
| `.badge` | 10 | 10 | 10 | 10 |

The badge and the warning marker sit on the desktop at the avatar, not in the conversation, so they never scale; the peek's "+N more" tag is in the conversation and uses `.caption` (it used `.badge`), so it grows with the text. At Small the pixel title is the body size and reads as a title by its gold color alone, as bold already does (D10). Tests: every pixel size is a multiple of 5.5; every SF Mono size is a multiple of 0.5; Default equals the pre-FS1 sizes.

### 19.3 What holds at every size

- **Line heights follow the font**; nothing else is scaled. Spacing tokens, the 2-px pixel, button padding, the 22-pt ⋯ and ✕ targets, glyphs (`ZeusGlyph`), the typing dots and the progress bar keep their sizes. The typing row and the composer stay baseline-aligned because both take their height from the body font.
- **Line limits count rendered lines** (peek body, chip summary, strip), so a bigger font shows fewer words, never a clipped glyph. The peek keeps its 200–280 pt width and the panel its widths; the composer grows to `composerLines` lines as before.
- **Truncation, not overflow:** one-line items (status strip, chip names, session labels, the kind line's label) truncate in the middle or at the end as they do today. Chips and option buttons wrap onto new rows (`ZeusChipFlow`, the options' wrap) rather than squeezing.
- **The status strip** (§15) is the one fixed-height row: `ZeusStatusStrip.height(for: choice, scale:)` returns 24 at Default (the value `ZeusStatusStrip.height` has today) and otherwise the caption's line height plus the strip's vertical padding, never less than 24; the strip lays out to at least that height and the app reserves what it returns, so a Larger caption never clips.
- **Short displays at Larger:** the peek still fits (`PeekLayout` measures with the scaled font), and the thread scrolls; nothing overlaps the composer.
- Changing the size takes effect at once everywhere, without a relaunch; the peek re-measures if it's showing.
- Not now: following the macOS accessibility text size. A later preset could map the system's Dynamic Type categories onto these four.

### 19.4 Renders

`fs1/fs1-<size>-<theme>-<scheme>-<font>`: a thread with a title, body, chip, rating line and strip, plus the peek, at each of the four sizes, light and dark, both fonts, from `build/fs1-renders/`. The Larger-pixel-short render shows the peek on a 240 pt-tall display.

## 20. Jump pills (JB1)

Slack-style floating buttons over the thread: one at the top for what the user has not read yet, one at the bottom for the newest message, and one for the next open question on whichever side it is. They replace the "↓ New message" button. Components: `ZeusJumpPill` and `ZeusJumpPillCluster` in `ZeusConversation.swift`; the app decides what to show with a pure helper over `visibility.navigationIDs` (no per-frame geometry), and every click reuses a jump the panel already has.

### 20.1 Which pills, and when

| Pill | Shown while | Label | Click |
|---|---|---|---|
| **Unread** (top) | unseen agent messages sit *above* the viewport. Unseen means not the user's, not a notice, not rating-held and not in `seenIDs`: the `unseenBelow` rule, looking up. | `↑ 3 unread` (`↑ 1 unread`) | scroll to the **oldest** unseen message, anchored at the top (the same jump as the strip's "Show", §15.2). The messages become seen as they show (§7), so the count falls and the pill goes away on its own. |
| **Latest** (bottom) | the user is scrolled up by more than about a viewport, or unseen messages sit *below* the viewport. | `↓ 2 new` when something unseen is below, else `↓ Latest` | `latest(proxy)`, the same as ⌘↓. |
| **Question** (top or bottom) | an open question (`StatusStripState.questions`) is off-screen. | `↑ ? Question` / `↓ ? Question`, or `↑ ? 2 questions` with the count of open questions | the strip's jump (§15.2): the next question in the shared cycle, through the one `lastQuestionJump`, so the pill, the strip and ⌘J never double-step. Focus lands on its first control, as today. |

- **Direction.** The question pill's arrow points at the *next* question the shared cycle will jump to; the pill sits in the cluster on that side. The unread pill always points up and the latest pill always down.
- **Counts** are plain integers in the label, never "9+"; the pixel font is monospaced, so the pill just widens.
- **Opening the panel** scrolls to the bottom and marks what shows as seen (§2). The pills are evaluated after that scroll lands, so nothing flashes during the open. Unread state persists across opens (`seenIDs`); an old pile of unseen messages shows the unread pill on the next open too, which is the point.
- **Not shown:** in the peek bubble, in an empty thread, or while the panel is closing. Progress updates and typing never count as new. In the document viewer the clusters float over the document with the rules in §21.9.

### 20.2 Anatomy and placement

```
 ┌──────────────────────────────────────────┐
 │        ┌─────────────┐ ┌──────────────┐  │  top cluster: centered, Spacing.xs below the thread's top edge
 │        │ ↑ 3 unread │×│ │ ↑ ? Question │  │  pills Spacing.xs apart; unread first, then the question
 │        └─────────────┘ └──────────────┘  │
 │ ┌ Talk tomorrow ───────────────── 8:02 ┐ │
 │ │ …                                    │ │
 │                 ┌─────────┐              │  bottom cluster: centered, Spacing.xs above the thread's bottom edge
 │                 │ ↓ 2 new │              │  (the strip and the composer are below the thread, so a pill never covers them)
 │                 └─────────┘              │
 │ ? 2 questions · Go to oldest · Skip  …   │ ← status strip, untouched
```

- **One pill:** `.caption` text in `palette.text`, padding `Spacing.s` horizontally and `Spacing.xs + pixel` vertically, at least **22 pt** tall (the standard target), on a `PixelRoundedRectangle(steps: 1)` filled `palette.panel` with a 1-px `palette.outline` and the panel's hard shadow (`palette.shadow`, offset one pixel right and two down, as `.zeusDialog` draws it). That shadow is what makes it float; nothing is blurred or translucent.
- **The arrow and the count** are in `palette.title` when the pill has something new (`↑ 3 unread`, `↓ 2 new`, every question pill); `↓ Latest` is all `secondaryText`, because nothing is waiting there. The question pill's `?` is the avatar's glyph in `palette.title`, as on the strip.
- **Hover:** fill `palette.field`. **Press:** the pill drops onto its shadow (offset one pixel down, shadow gone), as buttons do. **Focus:** the outline becomes `palette.focusRing` (the field rule, §8), no system ring.
- **Mark as read (×):** only on the unread pill. A `ZeusGlyph(.close)` in `secondaryText` (`title` on hover) in its own 22-pt target at the trailing end, after a 1-px `palette.divider` rule the text's height, inside the same capsule. Click marks every unseen message above as seen (`seenIDs`), which also clears the badge and the "!" if nothing else is unseen; the pill fades out. Tooltip "Mark as read". It is a separate button: its own focus stop and its own accessibility label; it never jumps.
- **Both pills on one side** sit side by side in one row, `Spacing.xs` apart, centered as a group: the unread or latest pill first, the question pill second. They are never stacked vertically, so the cluster covers one row of the thread at most.
- **Over the thread, not in it.** The clusters are overlays on the thread's scroll view; the thread's content and its scroll range don't change when a pill appears. A pill may cover a bubble's first or last line; it goes away as soon as the user acts on it or scrolls past what it points at. The top cluster covers the "Load earlier messages" line while it shows; the line is still reachable by Tab.
- **Text size** (§19): the pill's text and height follow `\.zeusFontScale`; padding, the pixel outline, the 22-pt minimum and the × glyph don't scale.

### 20.3 Narrow form

When the two pills of a cluster don't fit in the thread's width minus `2·Spacing.m`, both switch to their short labels in the same row (`ViewThatFits`: the full row, else the short row). A lone pill is never shortened. At the Larger pixel size two full pills no longer fit the 348-pt thread, so a two-pill cluster is short there by design; a single pill keeps its words.

| Pill | Full | Short |
|---|---|---|
| Unread | `↑ 3 unread` + × | `↑ 3` + × |
| Latest | `↓ 2 new` / `↓ Latest` | `↓ 2` / `↓` |
| Question | `↑ ? Question` / `↑ ? 2 questions` | `↑ ?` (the count moves to the tooltip and the accessibility label) |

### 20.4 Motion

- **Appear:** fade in over 120 ms ease-out while sliding 4 pt in from its edge (the top cluster slides down, the bottom cluster up). **Disappear:** fade out over 120 ms, sliding back. A pill joining a cluster moves the other pill over with the same 120 ms curve.
- **Counts** change in place with no animation.
- **Reduce Motion:** opacity only, no slide, no reflow animation; the jump itself lands without an animated scroll (§15.4).
- The pills never animate while the panel is resizing or while the thread is following a new message at the bottom; `\.zeusAnimationsActive` gates them like the typing dots.

### 20.5 Keys and accessibility

- No new keys. ⌘↓ is the latest pill, ⌘J the question pill (§15.4), ⌘↑ the top of the thread; the keys work whether or not a pill shows. The unread pill has no key; the strip's "Show" (⌘J while "!" shows) is the same jump.
- **Tab:** each pill is one focus stop, the × a second; the top cluster comes right after the composer, then the bottom cluster, then the thread wraps back to "Load earlier messages". Return and Space activate.
- **Labels:** the unread pill "Jump to 3 unread messages" ("Jump to 1 unread message"), the × "Mark unread messages as read", the latest pill "Jump to the newest message" with "2 new messages. " in front when there are, the question pill "Jump to the next question" ("Jump to the next of 2 questions"). The short form keeps the full label. VoiceOver reads the direction as "above" or "below" after the label.
- **Tooltips** (`.help`, system font): "Jump to the oldest unread message", "Mark as read", "Jump to the newest message (⌘↓)", "Jump to the next question (⌘J)" with the count in front when there are several ("2 questions · Jump to the next (⌘J)").

### 20.6 Component

```swift
ZeusJumpPill(.unread(3), onMarkRead: { … }) { jump() }
ZeusJumpPill(.latest(newCount: 0)) { jump() }
ZeusJumpPill(.question(count: 2, direction: .up)) { jump() }
ZeusJumpPillCluster(edge: .top, items: [.init(.unread(3), action: …, onMarkRead: …), .init(.question(count: 1, direction: .up), action: …)])
```

`ZeusJumpPill.Kind` is `.unread(Int)`, `.latest(newCount: Int)` or `.question(count: Int, direction: .up | .down)`. `ZeusJumpPill.title(_:compact:)` and `accessibilityLabel(_:)` are the copy; tests read them rather than restating the strings. The cluster lays out one or two items for its edge, picks the full or short labels, and carries the slide-and-fade transition for that edge; the app places one cluster per edge in an `.overlay(alignment: .top / .bottom)` on the thread and keeps the pills' state in `ConversationJumpState`.

### 20.7 Renders

`jb1/jb1-<state>-<theme>-<scheme>-<font>-<size>` from `build/jb1-renders/`: `unread` (top, with ×), `latest`, `new` (bottom, `↓ 2 new`), `question-above` and `question-below` (two pills in a cluster), `narrow` (a 260-pt thread: the full row still fits at Default, and the short row shows at Larger), `short` (a 160-pt thread with both clusters), light and dark, both fonts, Default and Larger.

## 21. Document viewer (DV1)

Click a file or folder chip and the panel turns into a reader for it, with the composer still underneath. The user asked for this as a productivity feature: room to read, real rendering, live updates when the assistant edits the file, and a way to talk about the document without leaving it. Components: `ZeusViewerHeader` (with `ZeusViewerHeaderModel` and `ZeusViewerMenuItem`), `ZeusViewerContextLine`, `ZeusViewerStatus` (its `Copy` holds every state message), `ZeusFolderRow`, `ZeusFindBar` in `ZeusViewer.swift`, and `ZeusMarkdown`'s document layout (`layout: .document`, `documentSegments`, `HeadingLevelAttribute`); native text hosts take sizes from `ZeusTextRole.size(for:scale:)` and fonts from `ZeusFonts.ctFont(_:choice:scale:)`; the app owns the viewer state, the back stack, the renderers (text, PDFKit, Quick Look, images), file watching and the panel resizing.

### 21.1 Opening, Back and the stack

- **Opens from** a file or folder chip in the thread (click, Return or Space, §18.5), a chip in the peek bubble (the panel opens straight into the viewer), a row in a folder listing, or a local link in a Markdown document. Links (`url`) keep opening in the browser. Reveal-only targets (apps, scripts, packages, aliases, executables: `AttachmentTarget.requiresReveal`) never enter the viewer: the chip or row shows them in Finder exactly as today, with the safety caption.
- **The file is read at click time** through `AttachmentTarget`: resolved, revalidated, and only that file. Nothing is fetched from the network, ever.
- **Back** (`‹ Messages`, Esc, ⌘[) pops one level: a linked document returns to the document that linked it, a previewed file returns to its folder listing, and the root returns to the thread. Leaving the viewer restores the thread **exactly**: the same scroll offset, keyboard focus on the chip you came from (or the composer if you came from the peek), and the composer draft untouched, except that a document the viewer attached by itself leaves with an empty draft (§21.8, "Auto-attached or explicit"). Esc closes the panel only when there is nothing to go back to; with the find bar open, Esc closes the find bar first.
- **The stack is per open.** Closing the panel while a document shows keeps the viewer; reopening the panel returns to it (the thread's focus and scroll are still saved underneath). Clear Conversation or Delete Everything leaves the viewer and drops the stack.
- **Transition:** the thread slides out to the left while the viewer slides in from the right, 180 ms ease-out, the header and the strip staying put; Back reverses it. A step to the next attachment slides left, to the previous right; a folder → file or document → linked-document push slides like an open. Reduce Motion: a 120 ms cross-fade, no movement.

### 21.2 Size: chat size and Expanded

- **Chat size** is the default. The viewer takes the panel's current width (the user may have resized it, `ConversationWidth`) and the thread's **maximum** height for this screen, `min(maxThreadHeight, maxHeightFraction × visibleFrame.height − composer − strip)`, not the content-fitting height a short thread has, so a document never opens into a 160-pt slot. The panel grows per §2's anchor rule and keeps its tail on the avatar.
- **Expand** (the header's ⤢ icon, ⌃⌘F, tooltip "Expand"): the panel animates to the reading size: width `ConversationWidth.clamp(2 × chat width, screenWidth)` (twice the chat width, at most half the screen), height the full visible frame minus 8 pt margins, re-anchored so it stays on screen with the tail still pointing at the avatar (offset clamped as §2). The content re-wraps live. **Collapse** (the same icon, now ⤡, tooltip "Collapse", ⌃⌘F) animates back. 200 ms ease-in-out; Reduce Motion: the frame jumps.
- **Memory:** `viewer.expanded` persists; the next document opens at the size the last one was left in. Back to Messages always returns to chat size (animated, or instantly under Reduce Motion), so the thread never appears at reading size.
- The user's own width drag and ⌥⌘←/→ keep working in the viewer; they set the chat width (and the expanded width follows as 2× of it).

### 21.3 Header

```
│ ‹ Messages                      [▣ Open in Keynote]  ⌕  ⋯  ⤢ │  row 1: actions, 24 pt
│ Q3 Planning.md · ~/Documents/Talks                  ‹ 2/3 › │  row 2: title, 24 pt
│ From: Here's the first draft. Slides 7–9 need your… Updated │  row 3: context line, 20 pt
├──────────────────────────────────────────────────────────────┤  1 px, palette.divider
```

- **Row 1.** Leading: `‹ Messages` in `palette.title`, `.caption`, a `ZeusGlyph(.left)` before the word, one 22-pt button with the strip's focus underline (§15.1); it reads "‹ Talks" (the folder's name) or "‹ Back" (a linked document) when Back pops to a folder or a document instead of the thread. Trailing, 2 pt apart, each a 22-pt target: **Open in <App>** as a `ZeusButtonStyle(.secondary, size: .small)` with the default app's 12-pt icon (`NSWorkspace` icon, supplied by the app as an `Image`) before the name, tooltip "Open in Keynote (⌘O)"; **Show in Finder** as the chip's `magnifyingglass` at 11 pt (`secondaryText`, `title` on hover or focus), tooltip "Show in Finder (⌘⇧R)"; **⋯** as `ZeusGlyph(.more)`, tooltip "More"; **Expand / Collapse** as a 12-px pixel icon (`ZeusViewerHeaderModel.Icon.expand` / `.collapse`, drawn like the strip's icons), tooltip "Expand (⌃⌘F)" / "Collapse (⌃⌘F)". When the row doesn't fit, "Open in Keynote" drops its words and keeps the icon (`ViewThatFits`); the tooltip keeps the name. No default app: the button reads "Open" with no icon.
- **Row 2.** The file name, `.body` in `palette.text`, one line, `truncationMode(.middle)`; then " · " and the location caption (`AttachmentTarget.locationCaption`, `secondaryText`) which truncates first. Folders show the folder name. Trailing, when the message has several **viewable** attachments (FX6): `‹ 2/3 ›`, the two glyphs as 22-pt buttons (`secondaryText`, `title` on hover), tooltips "Previous attachment (⌃⌘←)" / "Next attachment (⌃⌘→)", the count in `.caption` `secondaryText`. Viewable means a file or folder the viewer can show: not a link, not reveal-only, not missing, not invalid (§21.1). Those never count and are never stepped to, so `plan.md` + `run.sh` shows no stepper at all and `plan.md` + `run.sh` + `deck.pdf` shows `1/2` and steps md ↔ pdf. A document that goes missing while open keeps its place in the count until the next open. Stepping keeps the stack at the root.
- **Row 3, the context line** (`ZeusViewerContextLine`): "From: " in `secondaryText` then the message's takeaway, `.caption` in `palette.text`, one line, tail-truncated: the card's title if it has one, else the first sentence of its body (`ZeusMarkdown.spokenText`). The whole line is one button: it goes Back to Messages scrolled to that message with its chip focused; tooltip "Go to this message". A file opened from a folder reads "In: <folder name>"; a linked document reads "Linked from: <document name>". Trailing: the live mark (§21.8) or, for a PDF, "Page 3 of 12" in `secondaryText`.
- **The ⋯ menu:** Copy Path · Open With ▸ (the app supplies the apps) · Show Source / Show Rendered (Markdown only, ⌥⌘U) · Ask About This · Quote in Reply (enabled with a selection) · Find… (⌘F, when the renderer supports it).
- Colors from the palette only; the rows sit on `palette.panel` with the strip's 1-px `divider` under row 3. Everything scales with `\.zeusFontScale` except the icons and the 22-pt targets (§19.3).

### 21.4 Content area

The area between the header and the status strip. One renderer at a time, chosen by type (`UTType`), in this order: Markdown (`.md`, `.markdown`, `net.daringfireball.markdown`), plain text and code (`public.plain-text`, `public.source-code`, `.json`, `.yaml`, `.csv` is Quick Look), images (`public.image`), PDF, everything else Quick Look, and `ZeusViewerStatus` when none applies. Padding `Spacing.m`; content scrolls vertically inside the area; the JB1 pills float over it (§21.9).

| Kind | Rendering |
|---|---|
| **Markdown** | `ZeusMarkdownText(…, layout: .document)` (§21.5), selectable, wrapped at the content width. **Source** toggle (⋯ menu, ⌥⌘U) shows the file as text/code; the choice is per document and not persisted. Local images from the document's own folder render inline; remote images are never loaded. **Links (FX6):** an `http(s)` link opens in the browser. A link to a local file or folder opens it in the viewer as a push (§21.1: "Linked from", Back returns here). An **anchor** (`#overview`, or any link that resolves to the open document itself, including `Plan.md#overview` from inside Plan.md) scrolls the document so that heading sits at the top of the content area: no slide, no new page, no "Linked from", Back count unchanged; the find bar and the selection are left alone. `Notes.md#part` opens Notes.md as a push and then scrolls it to the anchor. Headings match by GitHub slug (lowercased, spaces to hyphens, punctuation other than hyphens dropped, repeated headings get `-1`, `-2`); the Source view keeps the same behaviour on its link runs. An anchor with no matching heading does nothing, quietly. `mailto:` and other schemes do nothing. |
| **Text and code** | `.body` in `palette.text` (both fonts are monospaced), selectable, soft-wrapped at the content width, tabs as four spaces, no line numbers. Links in a native text host take `palette.link` with a single underline, as in bubbles. An empty file shows "This file is empty." (§21.7). |
| **Images** | Native, centered in the area (both axes) on the panel colour; fitted to the width when the image is wider than the area, at its natural size when smaller (never upscaled); ⌘+ / ⌘− / ⌘0 (fit) and pinch zoom; scrolls when larger than the area. Animated images play unless Reduce Motion is on. |
| **PDF** | PDFKit, continuous vertical pages fitted to the width on the panel colour (the view's background is `palette.panel`, not PDFKit's grey), the same zoom keys, the page indicator in the context line; ⌘F searches. |
| **Everything else** (docx, xlsx, pages, keynote, csv, html, video, …) | Quick Look (`QLPreviewView`), the same preview as Finder's Space, rendered out of process, filling the area with no chrome of its own. Quick Look's own interaction (pages, playback) is kept. No find. |
| **Folder** | A folder listing (§21.6). |

- **Size cap:** text, code and Markdown files over **5 MB** show the first 5 MB, cut at a line end, then a `ZeusViewerStatus` footer: "Showing the first 5 MB." with "Open in <App> for the rest." PDFs, images and Quick Look previews have no cap of their own.
- **Selection** is native text selection in text, Markdown (rendered and source) and PDF. The selection's context menu adds "Quote in Reply" (§21.8) above the system items.
- **Find** (⌘F, text, Markdown and PDF): `ZeusFindBar` slides down under the header (120 ms, instant under Reduce Motion): a `ZeusTextField("Find")`, a count "2 of 7" (`.caption`, `secondaryText`; "No matches" when none), `‹` `›` glyph buttons (22 pt, tooltips "Previous (⇧Return)" / "Next (Return)"), and "Done" as a plain `title`-coloured text button (Esc). Matches are highlighted in `palette.accent` at 35 %, the current one in full `accent` with `onAccent` text, and the view scrolls the current match to the middle. The bar keeps its text while the document is open; ⌘F with the bar open selects the field's text.

### 21.5 Markdown document styles

`ZeusMarkdown.attributed(_:choice:palette:layout:)` gains `layout: .message` (today's rendering, the default) and `.document`. The document layout is for reading at length, in both fonts and every theme:

| Block | Document layout |
|---|---|
| Paragraph | `.body`, `palette.text`, one blank line between blocks, single line breaks kept (as today). |
| H1 | `.title` role in `palette.title`, a blank line before and after. |
| H2 | body size, `palette.title`, strongly emphasised (bold in SF Mono; the pixel font's bold is the title colour already), a blank line before, one newline after. |
| H3–H6 | body size, `palette.text`, strongly emphasised; in the pixel font they read as H2 does (two heading levels is what the font gives; the structure is still in `spokenText` for VoiceOver). |
| Lists | `•` / `–` / `1.` markers in `secondaryText` with two-space nested indents, as today. |
| Task items (`- [ ]`, `- [x]`) | the marker becomes `□` (`secondaryText`) or `■` (`palette.title`); a done item's text goes `secondaryText`. Both glyphs are in Departure Mono. This one also applies to messages, so an assistant's checklist reads the same in a bubble. |
| Quotes | `▌ ` bar and text in `secondaryText`, as today. |
| Code blocks | the tinted block pads to the longest line instead of the message layout's 36-column cap, so it reads as one block across the document; long lines soft-wrap. Inline code keeps its tint. |
| Tables | monospaced columns: each cell padded to its column's width, cells joined with ` │ `, the header row emphasised and followed by a rule row of `─` and `┼`; a table wider than the area wraps its rows rather than clipping (not pretty, but never hidden). |
| Rules | a `─` line 24 characters long, `secondaryText`. |
| Links | `palette.link`, underlined. A relative or `file:` link to a previewable local file opens it in the viewer (pushing the stack); `http(s)` opens the browser; anything else does nothing and the tooltip shows the target. |
| Images | an image on its own line (`![alt](path)`) splits the text: `ZeusMarkdown.documentSegments` returns `.text` and `.image(path, alt)` runs; the app draws a local image from the document's folder (fitted to the width, at most 320 pt tall, the alt text as a caption in `secondaryText` under it) and never loads a remote one: it shows "[image: alt]" in `secondaryText` instead. Inline images inside a sentence render as that placeholder too. |

The same `spokenText` serves VoiceOver in both layouts.

### 21.6 Folder listing

```
│ ▸ Notes                      Folder        Today 8:02  │
│ ▢ Outline.md                 Markdown      Yesterday    │
│ ▢ Q3 Planning.key            Keynote       12 Oct       │
```

- One `ZeusFolderRow` per entry, 22 pt min, full width, `Spacing.xxs` apart: the kind's SF Symbol at 11 pt (`folder.fill`, `doc.fill`, the chip's symbols) in `secondaryText`, the name `.body` in `palette.text` one line middle-truncated, the kind (`UTType.localizedDescription`, or "Folder") and the modified date (§3's divider format without the time for older days) both `.caption` `secondaryText`, right-aligned in two columns (kind 80 pt, modified 76 pt at the Default size, scaling with the caption) that drop one at a time before the name would truncate (`ViewThatFits`: kind goes first; the tooltip keeps "Kind · Modified"). At the chat width that keeps both columns for names up to about 16 characters.
- **Kind:** "Folder" for folders; the type's description with its first letter capitalised ("Text", "PDF document"); a file without a description shows its extension in capitals ("SWIFT"), or "Document" when it has none.
- **Order:** folders first, then files, each A–Z case-insensitive. Hidden entries (dot files, `.DS_Store`) are skipped. At most 500 rows, then one caption line "and 212 more · Show in Finder" whose link reveals the folder.
- **Click** (or Return/Space on a focused row): a file previews, pushing the stack; a folder steps into it, with `‹ <parent name>` as Back. Reveal-only entries show in Finder and the safety caption appears as a caption line under the list for 4 s. Hover: `palette.field` fill; focus: the field focus ring, as chips.
- **Header actions** act on the folder being shown: Open opens it in Finder (the button reads "Open in Finder" with Finder's icon), Show in Finder selects it in its parent, Copy Path copies its path.
- **Empty:** `ZeusViewerStatus` "This folder is empty." **Unreadable:** "Zeus can't read this folder." with Show in Finder.
- Live: the listing refreshes when the folder changes (§21.8), keeping the scroll position and the selection.

### 21.7 States

`ZeusViewerStatus(icon:name:detail:message:actions:)` centers in the content area: the file's icon (the app passes Finder's 32-pt icon as an `Image`; `doc.fill` at 24 pt in `secondaryText` when there is none), the name `.body` `palette.text` (or `mutedText` when missing), a detail line `.caption` `secondaryText` ("Keynote · 1.2 MB · Modified Today 8:02"), the message `.body` `palette.text` centered and wrapped, then the actions as small buttons: the first `.primary`, the rest `.secondary`.

| State | Message | Actions |
|---|---|---|
| Unsupported (no renderer and Quick Look has no preview) | "No preview for this kind of file." | Open in <App> · Show in Finder |
| Missing (gone at click time or while open) | "Not found. Zeus will show the folder it was in." | Show in Finder (the nearest existing parent) |
| Unreadable (permission denied, unreadable bytes) | "Zeus can't read this file." | Open in <App> · Show in Finder |
| Too large (text, code, Markdown over 5 MB) | a footer under the shown part: "Showing the first 5 MB." | Open in <App> for the rest |
| Empty file | "This file is empty." | Open in <App> · Show in Finder |
| Empty folder | "This folder is empty." | Open in Finder |
| Loading | nothing for the first 150 ms, then "Loading…" `.caption` `secondaryText` centered | none |
| Reveal-only reached by a link or listing | "Zeus shows apps and scripts in Finder instead of opening them." | Show in Finder |

The header stays in every state, so Back, Open and Show in Finder keep working.

### 21.8 Live updates, Ask and Quote

- **Live:** the app watches the open file (and a listed folder). On change the renderer refreshes in place, keeping the scroll offset as a fraction of the content (and the current find match if it still exists), and the context line's trailing end shows **"Updated"** in `palette.positive`, `.caption`, for 2 s with a 300 ms fade (opacity only; nothing moves). VoiceOver: "Document updated". A file that disappears turns into the Missing state; one that reappears at the same path renders again.
- **Ask about this.** The composer stays under the viewer and its placeholder reads "Ask about Q3 Planning.md…". Typing the first character attaches the document to the draft: the usual draft chip (`ZeusAttachmentChip`, §5's draft flow) appears above the composer with its ×; removing it detaches and the draft doesn't re-attach until the next document. "Ask About This" in the ⋯ menu or the context line attaches it and focuses the composer without typing. Sending keeps the viewer open; the user bubble lands in the thread behind it, and the reply shows up as a `↓ 1 new` pill (§21.9).
- **Quote in reply** (⌘⇧', the selection's context menu, or the ⋯ menu): the selected passage goes into the composer as a Markdown quote, each line prefixed `> `, followed by a blank line with the caret after it, appended after a blank line if the draft already has text; the document is attached as above. Passages are trimmed and capped at 2 000 characters (the rest is cut with "…"). The user bubble renders it with `▌` bars.
- **Auto-attached or explicit (DV2).** A chip the viewer added by itself, from typing or Quote in reply, is there only because of the text it accompanies. It goes away on its own when the draft text becomes empty (deleting a quote, Select All and delete), and when the user leaves the viewer by any way back (‹ Messages, Esc, ⌘[, a pill, the strip, Clear Conversation) while the draft text is empty. If the draft still has text on leaving, the chip stays, so the user can finish the question in the thread. A chip added by "Ask About This" is explicit and is never removed by the app: only its × or sending clears it, even if the draft is empty. The chip disappears the same way a × removal does; nothing announces it. Typing again while the document is open attaches it again, unless the user removed it with × (the rule above). Order of events: Back first restores the thread, then the empty-draft check runs, so the user never sees the chip vanish behind the slide.
- **Stepping** (⌃⌘← / ⌃⌘→, the `‹ ›` in row 2) moves between the message's viewable attachments (§21.3) in their order, wrapping at neither end (the glyph goes 50 % when there is nothing further; the keys do nothing when the stepper is hidden). ⌥⌘←/→ stay the panel's width keys (§2), which is why stepping doesn't use them.

### 21.9 Pills, strip and interruptions

- New messages never leave the viewer. The JB1 clusters float over the content area at its top and bottom: `↓ 1 new` whenever unseen messages exist anywhere in the thread (there's no "Latest" in the viewer), and `↑ ? Question` / `↓ ? 2 questions` when a question is open (the arrow is the question's position in the thread, as the strip would jump). Clicking a pill goes Back to Messages at that target with the same jump as in the thread; the viewer stack is dropped.
- The status strip stays live under the content; its jump and Skip work and also leave the viewer.
- Opening the panel from the peek bubble's chip goes straight into the viewer for that attachment (no thread flash).

### 21.10 Keys and accessibility

| Key | Does |
|---|---|
| Esc, ⌘[ | Back (one level; the find bar closes first; the panel closes only from the thread) |
| ⌘O | Open in <App> |
| ⌘⇧R | Show in Finder |
| ⌃⌘F | Expand / Collapse |
| ⌘F | Find (text, Markdown, PDF) |
| ⌃⌘←, ⌃⌘→ | Previous / next viewable attachment of the same message (§21.3) |
| ⌘⇧' | Quote in Reply |
| ⌥⌘U | Show Source / Show Rendered (Markdown) |
| ⌘+, ⌘−, ⌘0 | Zoom in, out, fit (images, PDF) |
| Return, Space (chip or row) | Open in the viewer; ⌘Return still shows in Finder |

- **Tab order:** `‹ Messages`, Open in <App>, Show in Finder, ⋯, Expand, the step buttons, the context line, the content (one focusable scroll area; a folder listing's rows are each a stop), the find bar's field and buttons when open, then the composer, which wraps to the start.
- **VoiceOver:** the viewer is a group "Document: Q3 Planning.md, Markdown" (or "Folder: Talks"); opening announces "Showing Q3 Planning.md"; row 1's buttons carry their tooltip text without the key; the context line is "From the message: <takeaway>"; folder rows read "<name>, <kind>, modified <date>"; the find count is announced as it changes. Back puts focus on the chip it came from, which VoiceOver reads as usual.
- **Reduce Motion:** cross-fades for open, Back and stepping; the Expand frame jumps; the find bar and the Updated mark appear without movement. **Reduce Transparency:** the panel is opaque already.

### 21.11 Renders

`dv1/dv1-<kind>-<size>-<theme>-<scheme>-<font>` from `build/dv1-renders/`: `md`, `md-source`, `text`, `image`, `pdf`, `quicklook` (a .docx), `folder`, `missing`, `too-large`, `unsupported`, `find` (the bar with a current match), `quote` (the composer holding a quoted passage and the draft chip), at `chat` and `expanded`, light and dark, both fonts.
