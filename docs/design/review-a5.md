# Design Review: A5 Conversation Panel and Peek Bubble

- **Reviewer:** designer (D12).
- **Scope:** `Zeus/Cards/**`, `Zeus/Avatar/**`, and the shell wiring in `Zeus/App/ShellController.swift`, on `main` at 373cba0, reviewed at the code level against CONVERSATION.md (§1–§14) and CARDS.md §4/§5. No app code was edited.
- **Ranking:** by how noticeable each issue is to the human in everyday use.

**Overall: very faithful.** The behavior that makes Zeus feel conversational is all here and correct:
- the seen rules (viewport, 300 ms) and the "↓ N new" count;
- the reply chip's target, opt-out and re-arming; ⌘1–9 on the newest actionable card; the Tab loop;
- send outcome captions with Retry;
- peek replace-in-place with "+N more";
- auto-hide counted from the end of typing, hover pause with a 2 s floor, and the ✓ receipt for 0.6 s;
- `talking` synced to `ZeusPeekTiming`;
- a non-activating, first-mouse peek panel;
- above → beside → below placement around the **art bounds**;
- suppression for panel open, hidden, quiet hours and Focus;
- Esc closing the popover before the panel, and focus returning to the previous app.

The findings below are mostly spatial polish, and two of them come from wording in my own specs, which I've amended in this branch.

---

## High: the human will notice right away

### 1. The conversation panel's tail floats well above Zeus's head
- **Where:** `Zeus/Avatar/DialogPlacement.swift:15-17`, called from `ShellController.swift:337`.
- **Spec:** CONVERSATION.md §2 and CARDS.md §4 say the tail tip sits 4 pt above the sprite's **art**.
- **Code:** `let above = avatar.maxY` uses the **canvas** top. Zeus's canvas has 17 px of headroom for the raised bolt and emotes, which is 51 pt at scale 3. So the panel and its tail hover about 50 pt above his laurel, while the peek bubble (which uses art bounds) sits snug. The two look inconsistent side by side.
- **Fix:** give `DialogPlacement.place` the art rect that `positionPeek()` already computes (`ShellController.swift:402`), and use `art.maxY + 4` for the above case. Factor the art-rect computation into one helper shared by both.
  ```swift
  // DialogPlacement.place(avatar:art:anchor:size:screen:)
  let above = art.maxY + 4
  ```

### 2. The unseen badge floats in empty space and is blurry
- **Where:** `Zeus/Avatar/SpriteAvatarView.swift:41-45`.
- **Spec (amended):** CARDS.md §5. The old wording, "canvas top-right … scaled with the sprite", was mine and caused this.
- **Code, two problems:**
  - It's anchored to the canvas's top-right, which for most characters is empty headroom, so the badge looks detached from Zeus.
  - `.scaleEffect(pixelScale / 3)` gives 1.33× or 1.67× at scales 4 and 5, which blurs the pixel frame and text.
- **Fix:** place it at the top-right of the art bounds, overlapping by 4 pt, unscaled.
  - `SpriteLayout.artBounds` returns canvas pixels in bottom-left space. In SwiftUI's top-left space, the art's top-right corner is `artRight = art.maxX * scale` and `artTop = (canvas.height - art.maxY) * scale`. Compute these once per character and scale.
  - Draw the badge from a `.topLeading` overlay, offset to that corner, with no `.scaleEffect`:
  ```swift
  .overlay(alignment: .topLeading) {
      if status.badgeCount > 0 {
          ZeusBadge(count: status.badgeCount)
              .alignmentGuide(.leading) { $0[.trailing] }      // badge's trailing edge on the offset point
              .offset(x: artRight + 4, y: artTop - 4)
      }
  }
  ```

## Medium: noticeable in ordinary use

### 3. A late answer appears with no hint of what it answers
- **Where:** `Zeus/Cards/ConversationModel.swift:81-84` (answers are timestamped `respondedAt`), and `ConversationView.swift:263-299`.
- **Spec (amended in this branch):** CONVERSATION.md §4. The old spec said "right after the question card". The implementation's chronological placement is better for a conversation, since your reply lands where you're looking, so I amended the spec to match it.
- **Gap:** answering a question from far up the thread (or from the peek) puts "No" at the bottom with no context.
- **Fix:** in `ConversationBubble`, when `entry` is `.userAnswer(cardID:…)` and the previous entry's `sourceCardID != cardID`, show a right-aligned caption above the bubble:
  ```swift
  Text("↩ \(question.title ?? String(question.body.prefix(40)))").zeusFont(.caption).foregroundStyle(palette.secondaryText)
  ```

### 4. The warning marker doesn't match the badge style
- **Where:** `Zeus/Avatar/SpriteAvatarView.swift:46-53`.
- **Spec:** CARDS.md §5 calls for a badge-style marker (outline plus destructive fill). The code draws a plain red rounded square with no outline, at a fixed 20 pt, at the canvas top-left (the same headroom problem as #2).
- **Fix:** use the new **`ZeusWarningMarker()`** (added to ZeusDesign in this branch) at the art bounds' top-left, overlapping 4 pt. Update the hit rect in `AvatarInteractionView.mouseUp` (`:97`) and `toggleWarning` (`ShellController.swift:250`) to the same frame.

### 5. Thread attachment rows lost the pixel frame
- **Where:** `Zeus/Cards/ConversationView.swift:313-332`.
- **Spec:** §4 says to use `ZeusAttachmentRow`. The hand-built row exists so it can take the focus modifier, but it ends with `.padding(6).background(palette.field.opacity(0.5))`: a flat, square-cornered rectangle, unlike every other pixel element.
- **Fix:** keep the custom row (the focus support is good), but match the chrome with public shapes:
  ```swift
  .padding(ZeusTheme.Spacing.xs + ZeusTheme.pixel)
  .background {
      PixelRoundedRectangle(steps: 1).fill(palette.field.opacity(0.55))
          .overlay(PixelRoundedRectangle(steps: 1).stroke(palette.fieldBorder, lineWidth: ZeusTheme.pixel))
  }
  ```

## Low: polish

### 6. With the typewriter off, Zeus barely moves his mouth
- **Where:** `ShellController.swift:351` passes `typewriter: peek.types`, and `AvatarStatusModel.swift:60` turns that into length 0, giving 0.25 s of `talking`.
- **Spec (clarified in this branch):** §14.4 says that whenever the text isn't typing (Reduce Motion, or the typewriter setting off), Zeus talks for 1.2 s.
- **Fix:**
  ```swift
  let typing = typewriter && !reduceMotion
  let duration = typing ? ZeusPeekTiming.talkingDuration(length: ZeusPeekTiming.typedLength(card.body), reduceMotion: false)
                        : ZeusPeekTiming.talkingDuration(length: 0, reduceMotion: true)
  ```

### 7. Long thread messages type for a long time
- **Where:** `Zeus/Cards/TypewriterModel.swift:33`, a fixed 40 chars/s with no cap.
- **Spec:** the peek caps a reveal at 2.4 s (`ZeusPeekTiming.maxTypingDuration`). A 600-character message in the open panel types for 15 s, unless the user clicks.
- **Fix:** use the peek's rule. Rate = `max(40, count / ZeusPeekTiming.maxTypingDuration)`, so long text types faster rather than longer.

### 8. The context menu doesn't separate user characters
- **Where:** `ShellController.swift:480-485`.
- **Spec:** §9 says the 12 built-ins in roster order, then a separator, then user characters.
- **Fix:** insert `characters.addItem(.separator())` before the first character whose id isn't in `CharacterLibrary.bundledOrder`.

### 9. A peek answer error sits between the tail and Zeus
- **Where:** `Zeus/Cards/PeekView.swift:40-43`.
- **Spec:** §14.3 says the tail points at Zeus. With the tail on the bubble's bottom edge, the error box is placed under the tail, so the tail points at the error instead of Zeus. This is rare: it only happens on a persistence failure.
- **Fix:** put the error **above** the bubble when the tail is `.bottom`, and below it otherwise.

---

## Verified as matching the spec (no action)

**Peek (§14)**
- Triggers on message, question and content cards only; updates and progress never pop a bubble.
- Replace-in-place, and "+N more" counts unseen eligible arrivals since the panel last opened.
- Options and Reply… follow the layout rules; Reply… re-arms the chip (`rearmReplyTarget`); "+N more" opens the oldest unseen card without marking it seen.
- ✕ marks seen; a timeout doesn't.
- High priority never auto-hides.
- The panel can't become key and accepts first mouse.
- ⌥⌘Z and avatar clicks expand the visible bubble.
- It follows drags.
- Suppression: panel open, hidden, quiet hours, Focus.
- Reveal-once (a card typed in the peek never re-types in the thread).
- The enter/exit transition, Reduce Motion, and VoiceOver announcements.

**Panel (§2–§13)**
- 380 pt width and the thread height limits.
- Grouping (2 min, same speaker and session) and dividers (10 min or a day change, with the specified formats).
- Session labels only when the loaded thread has more than one session.
- High-priority gold frame; muted cards keep their attachments, with options closed.
- Progress updates in place.
- Delivery captions and Retry, and "· from iPhone".
- The activity row.
- `ZeusComposer` (no overlay placeholders remain), with the reply-target rule and ✕/⌘K/Backspace.
- Return/⇧Return, ⌘1–9, ⌘↓, Tab loop, ⌘,.
- Esc order (popover first); the panel closes when it resigns key; focus returns to the previous app; the draft persists.
- 300-item pages that load on scroll.
- Seen after 300 ms visible.

**Shell**
- The right-click menu items and order, the hotkey key equivalent shown on *Talk to Zeus*, and both hide durations.
- The menu bar template icon switching to the alert variant.

**Type and colors**
- `.zeusFont` roles throughout, `ZeusMarkdown` in thread bodies, and `ZeusPalette` tokens (no raw colors in the reviewed views).

## Spec changes made in this branch
- **CARDS.md §5:** the badge and warning marker anchor to the art bounds, unscaled. The marker is `ZeusWarningMarker`.
- **CONVERSATION.md §4:** answers are placed chronologically, with the "↩ <question>" caption when they aren't adjacent to their question.
- **CONVERSATION.md §14.4:** `talking` lasts 1.2 s whenever the text isn't typing.
- **ZeusDesign:** new `ZeusWarningMarker` (additive, tested).
