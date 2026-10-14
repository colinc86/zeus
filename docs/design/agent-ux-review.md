# Agent-Facing UX Review: `ZeusMCP.instructions` and tool descriptions

- **Task:** D4 cross-review. Reviewer: designer. File under review: `Packages/ZeusKit/Sources/ZeusProtocol/ZeusMCP.swift` (owner: platform), on `main` at 343b3c8.
- **Lens:** I read the text as the model will, at the start of every session with no other context. The question is whether the model will use Zeus *well*: right tool, right length, honest status, no spam, correct acks.
- **Verification:** every behavioral claim below was checked against `Zeus/Bridge/ZeusRuntime+Tools.swift`, `ToolArguments.swift`, `AttachmentTarget.swift` and `CardStackView.swift`.

## Summary

The current text is **correct** (the delivery and ack rules match the runtime) but **hard to act on**:

1. **`instructions` is four dense paragraphs.** Transport details ("pushWritten only means stdout was written") crowd out the guidance the model needs most. That guidance is: which tool when, how long a card should be, and what to do with a pending answer.
2. **Facts that change behavior are missing:**
   - Card bodies render **inline markdown only**. Headings, lists and tables show as raw text.
   - Cards are about **360 pt wide**.
   - `mood` is a **2.5-second reaction**, not a lasting state.
   - `zeus_set_status` lingers for **10 minutes** unless set back to `auto`.
   - File attachments need **absolute or `~` paths**, and URLs must be **http(s)**. Anything else silently fails to open.
3. **The ack rule is stated three times in three places**, and never once as a simple recipe.
4. **Some tool descriptions say what a tool does, not when to use it.** The model picks tools from their descriptions, so each one should open with its *use case*.

Priority:
- **P1:** the `instructions` rewrite (§1) and the markdown, length and attachment facts in the descriptions (§2).
- **P2:** wording polish (§2) and the runtime messages (§3).

None of this changes the schema or CONTRACT §4. All of it is text, except §3.

---

## 1. Proposed `ZeusMCP.instructions` (replace in full)

Design goals:
- Scannable sections.
- Rules stated as imperatives.
- One ack recipe.
- About 2,400 characters (the current text is ~1,900). Every session pays for it, so the added length has to earn its place.

```text
Zeus is the user's desktop companion: an animated character on their screen. It is how you talk to the user. Prefer Zeus over terminal output for anything the user should see.

WHICH TOOL
- zeus_say: short updates and FYIs (1–3 sentences).
- zeus_ask: decisions. Give 2–4 options with short labels; free text is on by default when there are no options.
- zeus_present: finished work. A title, a short summary, and the deliverables as attachments.
- zeus_set_status: what you're doing right now (thinking, working + progress). Set it back to "auto" when you finish.
- zeus_update_card / zeus_dismiss: keep a card current, or remove it once it's stale.

CARDS
- Cards are small (~360 pt wide). Body markdown is inline only: **bold**, *italic*, `code`, [links]. No headings, lists or tables. Put long content in a file and attach it.
- Attachments: kind file/folder with an absolute or ~ path, or kind url with an http(s) URL. Zeus opens them; it never runs commands.
- priority "high" is for time-sensitive items only. mood is the avatar's brief reaction (~2.5 s) when the card appears.

ASKING
- zeus_ask waits up to wait_seconds (default 45, max 600). If the user answers in time, the answer is your tool result; you're done.
- Otherwise you get {status:"pending", card_id}. Do not ask again. Continue other work or end your turn; the answer arrives later as a delivery.
- Use wait_seconds 0 when you don't need the answer now.

DELIVERIES (answers and messages that arrive later)
- Claude Code: a <channel source="zeus"> event. Its meta has kind (reply | userMessage), delivery_id, and card_id/option_id for replies.
- Other agents: a line starting [zeus delivery_id=d_… card_id=c_…], or items from zeus_get_responses.
- Recipe: handle it, reply through Zeus (not just the terminal), then call zeus_ack with its delivery_id.
  Calling zeus_update_card or zeus_dismiss with that card_id also counts as the ack.
- Deliveries can repeat. If you've already handled a delivery_id, just ack it again and move on.
- zeus_get_responses is for when push isn't available. Everything it returns is already acked, so only call it when you'll process the results.

ETIQUETTE
- Batch low-priority updates into one card. Don't narrate every step.
- Ask before big or irreversible actions.
- Respect quiet hours: if the avatar is sleeping, hold non-urgent cards.
- If a tool says Zeus isn't running, tell the user in the terminal once and carry on.
```

### Notes for platform

- **"if the avatar is sleeping, hold non-urgent cards":** agents can't see the avatar state today. Either:
  - return `{state}` from `zeus_set_status`, or add `quiet: true` to tool results while quiet hours are on (recommended, small); or
  - drop that bullet.

  AgentHome currently tells the agent to rely on the user's stated hours, so the bullet stays harmless either way.
- The `[zeus delivery_id=…]` text-injection format only applies once P4 (tmux/OpenCode) lands. It's fine to ship the text now.

---

## 2. Tool descriptions: proposed rewrites

The format is **use case first, then behavior, then gotchas.** Each one is a single sentence or two. Schemas are unchanged.

| Tool | Current (abridged) | Proposed |
|---|---|---|
| `zeus_say` | "Show a short user-facing markdown message. Use priority for urgency, mood for avatar expression…" | "Tell the user something short (1–3 sentences): an update, an FYI, or a reply to their message. Inline markdown only. Attach files or links instead of pasting long content. ttl_seconds makes the card expire on its own. Returns card_id." |
| `zeus_ask` | "Ask the user a decision with options and/or free text…" | "Ask the user to decide something. Give 2–4 options with short labels and stable ids (style primary for the recommended choice); free text is allowed by default when there are no options. Waits up to wait_seconds (default 45, max 600): you get the answer, or {status:\"pending\", card_id}. Pending answers arrive later as a delivery. Never re-ask while pending." |
| `zeus_present` | "Present a finished work product with a title, markdown body, attachments and optional actions…" | "Hand over finished work: a short title, a 1–3 sentence summary, and the deliverables as attachments (file/folder paths or http(s) URLs). Optional actions such as Looks good / Revise come back later as a reply delivery. Handle it, then zeus_ack." |
| `zeus_update_card` | "Update an existing card by card_id; text replaces the body, append_text adds to it…" | "Keep a card current: change its title or body (text replaces, append_text appends) or its progress (0…1, or null to hide the bar). For a long task, zeus_say once, then update its progress here instead of posting new cards. Passing a card_id also acks any replies to that card." |
| `zeus_dismiss` | "Dismiss a card that no longer needs the user's attention…" | "Remove a card that's stale or resolved (e.g. you got the answer another way). A pending zeus_ask on that card resolves as pending. Also acks replies to that card." |
| `zeus_set_status` | "Set the avatar state, optional detail and progress. ttl_seconds defaults to 600. Use auto to clear your override…" | "Show what you're doing: thinking, working (with progress 0…1), etc. detail is a short phrase shown when the user hovers the avatar. The override lasts ttl_seconds (default 600), so set state \"auto\" as soon as you finish. Don't leave the avatar saying working when you're idle." |
| `zeus_get_responses` | "Fetch queued user messages and replies when push is unavailable…" | "Fetch user replies and messages when push delivery isn't available (e.g. Codex or OpenCode without a connector). Every item returned is acked immediately, so process them all; skip any delivery_id you've already handled." |
| `zeus_ack` | "Acknowledge deliveries you have handled by delivery_id, including duplicates you ignored…" | "Confirm you've handled one or more deliveries (from a <channel source=\"zeus\"> event or a [zeus delivery_id=…] line). Ack duplicates too. Without an ack, Zeus resends with backoff." |
| `zeus_list_characters` | "List available characters and the currently selected character before choosing a costume." | "List Zeus's characters (costumes) and the current one. Only change costume when the user asks." |
| `zeus_set_character` | "Select a character by its id from zeus_list_characters." | "Switch Zeus's costume to a character id from zeus_list_characters. Only when the user asks." |

### Schema property descriptions (additive, P2)

Models read `description` on individual properties. Add one-liners for:
- `mood`: "Brief avatar reaction when the card appears (~2.5 s). Default talking."
- `priority`: "high = time-sensitive; jumps to the front. Default normal."
- `attachments[].target`: "file/folder: absolute or ~ path. url: http(s) URL."
- `options[].id`: "Short stable slug, e.g. yes / later."
- `options[].style`: "primary = recommended, destructive = irreversible."
- `ttl_seconds` on `zeus_say`: "Auto-dismiss after this many seconds."

---

## 3. Runtime messages: small changes with big agent impact (platform)

These are in `Zeus/Bridge/**` and are not text-only, but each is tiny.

1. **Name the bad keys.** Today the error is `"Unexpected arguments for zeus_say"`, so the agent has to guess which argument is wrong. Proposed:

   ```
   Unexpected arguments for zeus_say: message. Allowed: text, title, mood, attachments, priority, ttl_seconds.
   ```

   The common case is `message`/`body` in place of `text`, because `zeus_present` uses `body`.
2. **Reject attachments that can't open.** `AttachmentTarget` returns nil for relative paths and for non-http(s) URLs, so the row silently does nothing when clicked. Validate in `ToolArguments.attachments()` and throw:

   ```
   attachments[0].target must be an absolute or ~ path for kind file
   ```
3. **`zeus_update_card` / `zeus_dismiss` on an unknown card** return `{ok:false}` with no reason. Add `"error": "No open card c_… (it may have been dismissed or answered)"` so the agent stops updating a dead card.
4. **Status progress isn't displayed anywhere yet.** `AvatarStatusModel.progress` is stored but never rendered. Either:
   - (appdev) draw a `ZeusProgressBar` under the avatar while `working` has progress (CARDS.md-style, 6 px tall); or
   - stop advertising `progress` on `zeus_set_status` until it renders.

---

## 4. Checked and fine as-is

- Pending → delivery → ack semantics, card_id-as-ack, and `zeus_get_responses` auto-ack all match the runtime exactly.
- `zeus_ask` clamping (0…600, default 45) and `allow_text` defaulting to true without options match.
- The not-running error text is short and tells the agent what to say. It's verified end to end: `zeus-mcp` returns it with `isError: true` when the socket is absent.
- `protocolVersion 2025-06-18` and the `claude/channel` capability are advertised only for `--agent claude`. Verified against the built bridge.
