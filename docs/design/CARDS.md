# Card Panel: Visual Spec (v1)

> **Superseded in part by [CONVERSATION.md](CONVERSATION.md)** (CONTRACT §10, v2 conversation UX). The card stack, pager, compose box and card-kind layouts below are replaced by the conversation panel. These sections still apply: the badge and "couldn't reach agent" marker (§5), placement and the tail (§4), motion and accessibility (§7), and the do/don'ts (§8).

**Audience:** appdev, who implements this in `Zeus/Cards/**` using the `ZeusDesign` components.

See `docs/design/components-d2.png` for the rendered reference, or the `#Preview` in `ZeusComponentGallery.swift` for the live one.

**Units:** Measurements are in points. A **px** is one UI pixel: `ZeusTheme.pixel` = 2 pt. All chrome snaps to it.

## 1. Anatomy

```
 ┌────────────────────────────────────────┐  ← .zeusDialog(): outline · frame · panel, stepped corners
 │ TITLE (gold, .title)          ◀ 1 of 3 ▶│  ← header row: title + ZeusPager (only if >1 card)
 │                                         │
 │ Markdown body (.body), wraps, max ~12   │  ← body; scrolls inside the card past 240 pt
 │ lines before scrolling                  │
 │                                         │
 │ [■ Attachment label        Reveal Open]│  ← ZeusAttachmentRow, one per attachment
 │ [▮▮▮▮▮▮▮▮▮▮▮▮▮▯▯▯▯▯▯▯▯]  62%            │  ← ZeusProgressBar (progress cards / progress != nil)
 │                                         │
 │ [ Yes ] [ No ] [ Remind me later ]      │  ← options: ZeusButtonStyle(option.style); wrap to new rows
 │ [ Or type a reply…                    ] │  ← input: ZeusTextFieldStyle (TextEditor in ZeusFieldChrome if multiline)
 │ just now · from claude:~/Zeus      ✕   │  ← footer: caption, secondaryText; ✕ dismisses
 └───────▼─────────────────────────────────┘
         └─ tail points at the avatar (§4)
```

- **Width:** `ZeusTheme.cardMinWidth` to `cardMaxWidth` (260 to 360). Grow with content, and prefer the max when the card has options or attachments.
- **Padding:** the default of `.zeusDialog()`, which is `Spacing.m` (12) inside the frame. Separate sections with `Spacing.s` (8). Buttons sit `Spacing.s` apart.
- **Text roles:**

  | Role | Used for | Color |
  |---|---|---|
  | `.title` | Title | `palette.title` |
  | `.body` | Body | `palette.text` |
  | `.caption` | Footer, pager, attachment targets | `palette.secondaryText` |

  Use `.zeusFont(_:)` everywhere, and set `\.zeusFontChoice` once at the root from Settings.
- **Markdown:** render the body with `Text(AttributedString(markdown:))`, inline only (bold, italic, code, links). Links open via `NSWorkspace` and never run commands. Code spans use the system monospaced font at the body size.
- **Option order:** follow the agent's order. If there is a single `primary` option, put it first. Never more than one `destructive` option per row.
- **No title:** the body moves up into the header row's place, and the pager stays top-right.

## 2. Card kinds

| `Card.kind` | What's different |
|---|---|
| `message` | Body, plus attachments if any. ✕ in the footer. Auto-dismisses on `expiresAt`. |
| `question` | Options and/or input. The text field takes focus when the panel opens. Return sends (⌘Return when multiline). |
| `content` | Like `message`, but a bigger body area (max 18 lines before scrolling). Actions come from `options`. |
| `progress` | Title, one-line detail, `ZeusProgressBar(value: progress)`. `nil` progress shows the indeterminate bar. No ✕ while the agent is working. |
| `userMessage` | The user's own outgoing message, shown in history only. Right-aligned body, `secondaryFill` panel tint, no tail. |

## 3. States

| State | Look |
|---|---|
| open, unseen | Normal. The avatar is in `alert` (CONTRACT §7). |
| open, seen | Normal. |
| answered | Collapse to a one-line receipt: `✓ <response.summary>` in caption. Fade out after 1.5 s; with Reduce Motion, remove it at once. Disable buttons as soon as a reply is sent. |
| dismissed / expired | Remove. No receipt. |
| high priority | Jumps to the front of the stack. 1 px `accent` inner line under the frame (the same frame with `frame = palette.accent`). No other emphasis. |
| sending (reply in flight) | The clicked button stays pressed. Other controls are disabled (`.disabled`, 50% opacity). |
| delivery failed | No change to the card in v1: `Card` carries no delivery state (CONTRACT §8). The failure shows at the avatar level only (§5, "Couldn't reach agent"). |

## 4. Placement and the tail

- **Position:** the card panel sits above the avatar canvas when there's room, otherwise below. It's centered on the avatar's anchor x and clamped to the screen's visible frame with 8 pt of margin.
- **Tail:** use `.zeusDialog(tail:)`.
  - `ZeusDialogTail(edge: .bottom, offset: x)` when the card is above the avatar; `.top` when it's below.
  - `offset` is the avatar's anchor x, in the card's own coordinates, measured from its leading edge. Clamp it to `[16, width − 16]` so the tail never lands on a corner.
  - The modifier reserves `ZeusDialogTail.height` (10 pt) on that edge. The tail's tip should sit 4 pt from the top of the sprite's art box when the card is above, or 4 pt below the anchor when it's below.
- **Following the avatar:** when the user drags the avatar, the card panel moves with it in the same frame (no lag) and recomputes above/below and the tail offset live.
- **Shadow:** a hard drop shadow (1 px right, 2 px down) is built into `.zeusDialog()`. Don't add a system window shadow to the panel (`hasShadow = false`).

## 5. Stack, pager and badge

- **Stack:** one card is visible at a time. Behind it, draw up to 2 "peek" panels, each 3 px lower and 3 px narrower per side, using `PixelRoundedRectangle` filled with `palette.outline` then `palette.frame`. They only hint that more cards exist; they show no content.
- **Pager:** `ZeusPager(index:count:)` in the header when `count > 1`. ←/→ keys page while the panel is key. Order: high priority first, then newest first.
- **Badge:** `ZeusBadge(count:)` counts open cards.
  - It sits at the top-right corner of the sprite's **art bounds** (`SpriteLayout.artBounds`, not the canvas, whose emote headroom is empty space), overlapping the art by 4 pt. It's drawn **unscaled** on the 2 pt UI grid: fractional scaling blurs pixel chrome. It isn't part of the sprite render. *(Amended in D12: it was the canvas corner, scaled.)*
  - Hide it at 0. It caps at "9+". It's visible in every avatar state.
  - The badge always uses the dark palette because it sits on the desktop, not in a panel.
- **"Couldn't reach agent" indicator:** when a delivery is marked failed (CONTRACT §5.6), show `ZeusWarningMarker` (a badge-style red "!") at the top-left corner of the sprite's art bounds, overlapping 4 pt and unscaled. It stays until the delivery is acked or fetched via `zeus_get_responses`.
  - Hovering the avatar shows the tooltip "Couldn't reach the agent. Replies are saved for later."
  - The menu-bar item shows the same text.
  - It doesn't change the avatar's state, and cards stay as they are.

## 6. Compose box (no cards)

When there are no cards, clicking the avatar opens a compose card:
- a `.zeusDialog(tail:)` with the placeholder "Message <assistant>…" in `ZeusFieldChrome` (multiline, 1–5 lines);
- a primary **Send** button, plus ⌘Return.
- **Empty state:** if no assistant session is bound, show a caption with a secondary button **Open Settings**.

## 7. Motion and accessibility

**Appear**
- Fade in and move up by 3 px over 120 ms, ease-out.
- On the pixel grid, round the offset to whole px each frame. Don't scale or blur.
- With Reduce Motion: no movement, only a 120 ms opacity change.

**Typewriter text** (phase 2): reveal 40 chars/s, and a click completes the text immediately. Disabled under Reduce Motion.

**Reduce Transparency:** the panel is opaque (`.zeusDialog()` already handles this).

**Contrast:** text, titles and button labels all meet WCAG AA on their fills in both palettes.

**VoiceOver**
- Each card is one container labelled "<title>. <body>".
- Options are buttons, the pager arrows are labelled, and the badge reads "3 open cards".

**Keyboard**
- Tab cycles options → field → attachments. Esc closes the panel without dismissing the card.
- Number keys 1–9 choose options in order.
- Focus ring: a 1 px `palette.accent` line inside the button frame. Don't use the system ring, which clashes with the pixel corners.

## 8. Do and don't

- **Do** keep every edge on the 2 pt grid: widths and heights in even points, and offsets in whole px.
- **Do** mirror Mac and iOS: iOS uses the same components, with Reveal hidden.
- **Don't** use SF Symbols bigger than 13 pt or system materials inside cards. Blurs break the retro look.
- **Don't** set colors directly. Everything comes from `ZeusPalette`, so light and dark stay in sync.
