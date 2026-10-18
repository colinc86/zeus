# MCP tool reference

[Documentation](README.md) · [Connection setup](SETUP.md#4-connect-your-own-session-advanced) · [Engineering contract](CONTRACT.md)

`zeus-mcp` is a stdio JSON-RPC MCP server bundled in Zeus. It advertises protocol revision `2025-06-18`. Its 26 tools are listed below; tool discovery works even when the app is closed, but execution needs Zeus running.

Arguments are JSON objects. **Bold argument names are required**; omitted optional fields use the documented defaults. Names are case-sensitive: most use snake_case, while rule tools use `ruleID`, `wouldHave` and `approvalID`, and time triggers use `startMinute`/`endMinute`.

Results contain compact JSON text and `structuredContent`. Errors set `isError` and normally include an `error` string. Quiet hours can add `quiet: true`. A closed app returns: “Zeus app isn't running — ask the user to open Zeus.”

By default only the selected assistant can call tools. A former assistant can still acknowledge or fetch its own existing deliveries. Card update/dismiss is restricted to the owning session or a session that received an explicit handoff. Native permission prompts, purchase confirmations and local Terminal notices cannot be changed by those tools.

## Shared argument shapes

| Shape | Fields |
|---|---|
| Attachment | `{kind, label, target, summary?}`; string fields. `kind`, `label` and `target` are required. `kind`: `file`, `folder` or `url`. File/folder targets must be absolute or `~` paths; URL targets must be HTTP(S). `summary` is required for files/folders; see [attachment summaries](#attachment-summaries). |
| Option/action | `{id, label, style?}`. Unique string `id`, string `label`; `style`: `primary`, `secondary` (default) or `destructive`. |
| Mood/state | `idle`, `talking`, `thinking`, `working`, `alert`, `waiting`, `happy`, `sleeping`. `zeus_set_status` also accepts `auto`. |
| Priority | `low`, `normal` (default), `high`. High is for time-sensitive items; it does not bypass a stopped message kind. |
| Message kind (`about`) | Optional string for say/ask/present; a stable, plain label of 1–60 characters. Surrounding whitespace is trimmed; blank, control-character and punctuation-only labels are rejected. |
| Progress | Number 0–1, or `null` to remove it. |
| TTL | Nonnegative finite seconds. Omit for the tool's default. |

Keep card text short. Bodies support inline formatting, links, lists, headings, quotes and fenced code. Attach longer work as a file. Mood is a brief reaction; use status for ongoing work. High priority emphasizes a card without reordering the chronological thread.

## Attachment summaries

For `zeus_say` and `zeus_present`, put the takeaway in `text` or `body`: what you found or made, and what the user should do next. Attach a file or folder only when opening it adds something useful. Use a name for `label`, not an instruction such as “Open report”.

Each file/folder attachment needs `attachments[].summary`: 1–3 plain-text sentences explaining what is inside and why it matters. The runtime requires at least **20 non-whitespace characters** and at most **400 total characters**, including whitespace. URL summaries are optional, but any supplied summary must be a string of at most 400 characters; `null` is not accepted. The schema leaves `summary` out of the unconditional required list because links may omit it; file/folder validation still requires it.

A missing or too-short file/folder summary returns `isError` with this exact guidance:

> Each file or folder attachment needs a summary: 1–3 sentences saying what's in it and why it matters, so the user doesn't have to open it. Put the takeaway in the message text too.

An overlong summary returns an indexed error such as `attachments[0].summary must be at most 400 characters.` Zeus validates the whole array before posting: if any attachment fails, **nothing from that call reaches the thread**. Correct the arguments and retry. The sentence count and takeaway are writing guidance; the length limits are enforced.

Summaries appear in [compact attachment chips](CONVERSATION.md#attachments-from-your-assistant). Older stored cards without summaries remain readable. `zeus_update_card` cannot add or edit attachments or their summaries; text updates preserve them.

## Message kinds and ratings

Supply an honest, consistent `about` label on messages you send on your own, such as `"On-call reminder"` or `"Meeting prep notes"`. It identifies the kind the user can rate. Omission is supported; the UI falls back to a title or text excerpt. The assistant cannot set `origin` or a mute decision.

Zeus classifies a new card as a reply only while that session has an open, unexpired response to a user message or answer. Classification happens before posting ends that response. An explicit working/thinking status or a learning/reflection delivery alone does not make a reply. Replies are neither rated nor held by ratings; legacy cards without an origin are not assumed unprompted.

Only **Stop these** with kind scope holds new unprompted cards. Exact normalized labels take precedence, including explicit **More like this**/**Neutral** preferences; otherwise Zeus checks similarity against stopped kinds on the Mac. A held card is retained and the tool still returns its normal result, but it does not peek, sound or count as unread. `priority: "high"` cannot bypass this. Do not relabel or repeat a stopped kind to get it through.

**Neutral** means send only when the user needs to know, using your judgment; Zeus delivers those messages normally. **Just this one** is feedback without a kind rule. Ratings are explicit user preferences delivered through the normal acknowledgment flow, not rules to create with `zeus_propose_rules`. There is no MCP tool for setting or erasing the user's ratings.

Ordinary-priority unprompted cards count toward a limit of six per local day. Further cards still return their normal result but arrive silently held; replies and high-priority cards are exempt. Rating holds are applied first, so **Stop these** still wins. See [the daily limit](CONVERSATION.md#daily-limit-on-unprompted-messages).

## Conversation tools

### `zeus_say`

Post a short message. Returns `{card_id}`.

| Arguments | Type / default |
|---|---|
| **`text`** | String; message body. |
| `title` | String. |
| `about` | Optional message-kind label; see [message kinds and ratings](#message-kinds-and-ratings). |
| `mood` | Mood; the ordinary new-card reaction is talking. |
| `attachments` | Attachment array; empty. Files/folders require a [summary](#attachment-summaries). |
| `priority` | Priority; normal. |
| `ttl_seconds` | Number; no expiry when omitted. |

### `zeus_ask`

Ask a question and optionally wait for an answer.

| Arguments | Type / default |
|---|---|
| **`text`** | String; question body. |
| `title` | String. |
| `about` | Optional message-kind label; see [message kinds and ratings](#message-kinds-and-ratings). |
| `options` | Option array; empty. |
| `allow_text` | Boolean; true when there are no options, false otherwise. |
| `placeholder` | String for the reply input. |
| `multiline` | Boolean; false. |
| `priority` | Priority; normal. |
| `wait_seconds` | Number; 45, clamped to 0–600. Use 0 to return immediately. |

Results are `{status:"answered", card_id, option_id?, option_label?, text?}`, `{status:"skipped", card_id}`, or `{status:"pending", card_id}`. A pending question stays answerable; its answer arrives later as a delivery. Do not re-ask it. A skipped question should not be asked again.

The `allow_text` setting defines the tool's input specification. The conversation composer also permits a typed answer to an ordinary options-only question when no text-accepting question takes precedence.

### `zeus_present`

Present finished work. Returns `{card_id}`. Actions are answered later as reply deliveries.

| Arguments | Type / default |
|---|---|
| **`title`**, **`body`** | Strings. |
| `about` | Optional message-kind label; see [message kinds and ratings](#message-kinds-and-ratings). |
| `attachments` | Attachment array; empty. Files/folders require a [summary](#attachment-summaries). |
| `actions` | Option array; empty. |
| `allow_text` | Boolean; false. |
| `mood` | Mood. |
| `priority` | Priority; normal. |

### `zeus_update_card`

Update **`card_id`** (string). Optional `title`, `text` and `append_text` are strings; `progress` is 0–1 or null. `text` replaces the body, then `append_text` appends exactly, without adding whitespace. Omitted fields stay unchanged. Attachments and their summaries are preserved; supplying `attachments` is rejected.

Returns `{ok, title, progress, status}`. A missing card returns an error. A `card_id` supplied by the delivery's receiving session also acknowledges matching replies, even if the requested mutation subsequently fails validation.

### `zeus_dismiss`

Dismiss **`card_id`** (string). Returns `{ok:true}` or an error for a missing/inaccessible card. History remains as a muted card; a waiting `zeus_ask` resolves as pending. Also acknowledges eligible replies associated with that card.

### `zeus_set_status`

Set **`state`** (state string or `auto`). Optional `detail` is a short string, `progress` is 0–1 or null, and `ttl_seconds` defaults to 600.

Returns `{ok:true}`. `auto` clears the explicit override and current activity. Zeus also derives activity from delivery and native completion, so clear an explicit working status when finished. Status progress is separate from a card's progress bar.

## Delivery tools

### `zeus_get_responses`

No arguments. Returns a bounded batch:

```json
{
  "items": [],
  "delivery_mode": "tmux",
  "push_active": true
}
```

Each item has `delivery_id`, `kind`, `text`, `created_at`, and optional `card_id`, `option_id`, `option_label`. Kinds include `reply`, `skipped`, `userMessage`, `learning`, `reflection`, `brief` and `ruleTrigger`. `delivery_mode` is `channel`, `tmux`, `opencode` or `polling`; metadata describes the current route, not model comprehension.

Rating changes, removals, Undo and match corrections arrive as `kind: "learning"` deliveries, including when observation is off. Their text describes the preference and can end with `Files: Zeus/preferences.md`. Read the current file when present, generalize kind preferences, and keep useful dated conclusions in `Notes/preferences.md`. Single-message ratings do not appear in the file's kind list.

For a `brief`, the instructions call for one `zeus_present` with `about: "Morning brief"`, title "Today" and at most six lines, or a quiet acknowledgment when nothing matters.

A `ruleTrigger` identifies the rule, matched conditions and shadow/active status; shadow requires `zeus_rule_shadow` without acting, while an active rule permits action within its authority followed promptly by `zeus_rule_acted` while the trigger remains valid. Both use normal delivery and acknowledgment, include the remaining daily message allowance, and leave resulting cards classified as unprompted. They arrive here or through the active push route, not through `zeus_get_learnings`.

Returned items count as acknowledged once the result is successfully written/consumed. Process every returned item and poll until `items` is empty. It is valid to poll with any delivery mode.

### `zeus_ack`

Confirm **`delivery_ids`** (array of strings). Returns `{acked:[…]}` containing accepted IDs scoped to the receiving session.

For a channel event or a line beginning `[zeus delivery_id=…]`, handle the request, reply through Zeus, then acknowledge its ID. If an ID repeats, acknowledge it again without repeating the action. `zeus_say` does not implicitly acknowledge a delivery.

## App controls

The master **Let my assistant control Zeus** switch gates changes and update checks. **Let my assistant install updates** additionally gates installation. Reading app state and listing characters do not change preferences. Appearance changes produce local Undo notices; creation Undo keeps the new file. These tools cannot grant the agent more authority or enable learning.

### `zeus_app_state`

No arguments. Returns `version`, `build`, optional `updateAvailable`, `characterID`, `themeID`, `size`, `screen`, `position`, `screens`, `panelOpen`, `hidden`, optional `hiddenUntil`, `quietHoursActive`, `ghostMode`, `userIdleSeconds` and `formats`.

`position` contains `x`/`y` for the avatar's bottom-left corner on its display. `screens` contains display `width`, `height` and `scale`. `formats.character` and `formats.theme` identify the format documentation to read before creating JSON. The snapshot does not expose another agent's session state.

### `zeus_list_characters`

No arguments. Returns `{current, characters:[{id,name,description}]}` for installed characters.

### `zeus_set_character`

Select **`id`** (string) from the character list. Returns `{ok:true, previous, current}` and offers Undo.

### `zeus_create_character`

Requires **`name`** and **`json`**, both strings. `json` is the entire character file encoded as a string, not an object or path. The real character loader validates it before installation and selection. Returns `{ok:true, summary}`.

### `zeus_set_theme`

Select an installed theme by **`id`** (string). Returns `{ok:true, summary}`. Unknown IDs fail.

### `zeus_create_theme`

Requires **`name`** and **`json`**, both strings. Validates the full theme JSON text, installs and selects it. Returns `{ok:true, summary}`.

### `zeus_move`

Requires **`position`**: `top-left`, `top-right`, `bottom-left`, `bottom-right`, `near-active-window`, or `{screen, x, y}` with a nonnegative integer display index and finite numeric coordinates in screen points. Placement is clamped to the display. Prefer `near-active-window`. Returns `{ok:true, summary}`.

### `zeus_set_size`

Requires **`size`**: `small`, `medium` or `large`. Returns `{ok:true, summary}`.

### `zeus_hide`

Requires exactly one of **`minutes`** (integer 1–720) or **`until`** (`"tomorrow"`). Indefinite hiding is unavailable. Returns `{ok:true, summary}` and a **Show now** action.

### `zeus_set_appearance`

Supply at least one of the following fields; omitted values stay unchanged. Returns `{ok:true, summary}`.

| Field | Type / accepted values |
|---|---|
| `ghost_mode` | Boolean. |
| `ghost_opacity` | Finite number; clamped to 0.1–0.9. |
| `ghost_delay_seconds` | Finite number; clamped to 5–600. |
| `popup_sound` | Boolean. |
| `popup_sound_name` | `chime`, `glass`, `ping`, `pop`, `tink`. |
| `font` | `pixel` (Pixel) or `system` (SF Mono); changes the typeface only. |
| `panel_width` | Finite number in points; clamped to the supported width for the current screen. |
| `quiet_hours` | Boolean. False is rejected while a Zeus question is pending. |
| `quiet_start_hour`, `quiet_end_hour` | Integers 0–23, in local time. Equal hours mean all day. |

**Text size** is set in [Settings › Appearance](SETTINGS.md#appearance); `zeus_set_appearance` has no text-size argument.

### `zeus_check_for_updates`

No arguments. Checks without installing. Returns `available` (boolean), optional `version` and `notes`. A successful check records the available version for the calling session.

### `zeus_install_update`

Requires **`version`** (string), exactly as returned by a successful check in this session. Announces installation, waits for in-flight work and blocking prompts for up to 60 seconds, then proceeds if still enabled. The managed tmux assistant survives Zeus's relaunch.

Returns `{ok:true, version}` on success. There is no Undo. A failure is reported in the conversation and tool result, and once more to that session's next tool call.

## Learning and rules

### `zeus_get_learnings`

No arguments. Returns `{learnings:[…]}` containing unread digests and moments, oldest first, in a bounded batch. Each learning includes its `id`, `kind`, `createdAt` and `text`. Disabled learning returns an empty array. Rating deliveries use `zeus_get_responses` or the active push route instead and remain available with learning off.

When a folder copy is available, learning text includes a final `Files:` line with the relevant paths. Successful result consumption marks returned learnings read and creates their sent receipts. A notification alone does not. Use them to decide whether useful preparation or a short labeled update is needed now, within the user's permissions, ratings and daily message limit. Otherwise acknowledge quietly. They are not user requests, and private observations should not be quoted unprompted.

### `zeus_get_journal`

All arguments are optional.

| Field | Type / default |
|---|---|
| `query` | String, at most 256 characters; empty means no text filter. Plain substring search, not query syntax. |
| `from`, `to` | ISO 8601 date-time strings. `to` defaults to now; `from` defaults to 24 hours before `to`. A timestamp without an offset uses local time. |
| `kinds` | Array of `activity`, `focus`, `screen`, `typing`; defaults to all. Intersected with enabled levels. |
| `raw` | Boolean, false; requests stored pictures or retained words from enabled levels; there are no separate raw-access switches. |
| `limit` | Integer 1–50, default 20. |

The range must be ordered and no more than seven days. At most 20 calls per hour are accepted. Results are newest first, with item data bounded to 400,000 encoded bytes. Pictures retain the safeguards and picture-covering setting applied at capture. They are JPEG previews, at most 640 pixels on the longest side and 150,000 bytes each, also exposed as MCP image content.

Returns `answer_id`, redacted `query`, `from`, `to`, `range`, `items`, `raw` statuses, `raw_requested`, `off` and `note`. Items contain `id`, ISO time, app identifier, `kind`, `text`, and optional `words` or `picture:{mimeType,data}`. `raw.screen`/`raw.typing` say `allowed`, `not allowed` or `not requested`. Disabled kinds are listed in `off`.

Without `raw: true` and enabled Typing, search does not inspect retained words. Every consumed answer is recorded exactly in the Sent ledger; failed attempts are not sent receipts. Call for a relevant user request, not to browse unrelated history. The assistant can instead read the [folder record](LEARNING.md#your-assistants-folder); independent file reads do not create journal-tool receipts.

### `zeus_get_rules`

No arguments. Returns `{rules:[…], autonomy}` for active and shadow rules. Rule records include ID, sentence, trigger, kind, status, evidence, dates and author metadata. The returned `confidence` is a word: `Sure`, `Fairly sure` or `Unsure`. `autonomy` corresponds to Ask me first (0), Balanced (0.5) or Just do it (1). Spending rules include a `purchase_policy` explanation.

### `zeus_propose_rules`

Requires **`rules`**, an array of 1–3 proposals. At most three new agent rules can be proposed per day, in response to a recent reflection addressed to this session.

| Proposal field | Type / default |
|---|---|
| **`sentence`** | String, 1–500 characters. |
| `kind` | `passive` (default) or `acts`. A spending trigger forces acts. |
| `confidence` | Number; default 0.6, runtime clamps to 0.4–0.7. |
| `evidence` | Array of retained journal item IDs from the reflection; default empty. |
| `trigger` | Object described below; default empty guidance. |

Triggers accept `time:{startMinute,endMinute,weekdays?}`, `apps:[bundleID,…]`, `state` (string), and `kind:"spend"`. Time endpoints are required together and runtime validation accepts integers 0–1439. Weekdays use 1=Sunday through 7=Saturday; an empty list means every day. A window crossing midnight wraps. Trigger dimensions combine with AND. Unknown states do not match; an empty trigger never holds notifications.

Evaluable and spending rules need at least two evidence IDs from two different days represented in the reflection. Rejected/off/deleted fingerprints suppress re-proposal for 30 days. The sentence is redacted before storing. Returns `{rules:[…]}` with the new rules in the same agent-facing form as `zeus_get_rules`. Acting rules begin in shadow; proposal is not permission to act.

### `zeus_rule_shadow`

Requires **`ruleID`** and **`wouldHave`** (strings). `wouldHave` is a nonempty action description of at most 1,000 characters, ideally beginning with a past participle, such as `sent a short update`. Optional `amount` (positive number, maximum 1,000,000,000) and `currency` (three uppercase letters) are required for spending.

The rule must be in shadow and its evaluable trigger must match. Returns `action_id`, `approvalID`, `act:false` and `note`; an existing pending shadow result can return its `status` instead of a new notice. Do not act on this result. Wait for approval and read the rules again.

A purchase creates its own durable question with the amount. That approval is specific to the exact action and session, expires one hour after creation and is single-use; standing rule approval is insufficient.

### `zeus_rule_acted`

Requires **`ruleID`** and **`did`** (strings). `did` is nonempty and at most 1,000 characters. Optional `undo` is a reversal instruction of at most 1,000 characters; optional `approvalID` is required for spending.

Reports an action already performed under an approved rule with a matching trigger. It does not execute the action. A spending report must match the freshly approved action text and session. Returns `{action_id, ok:true}`. The notice offers Undo when an instruction was supplied, otherwise Not again. Undo delivers that instruction to the original session with an idempotent delivery ID.

Both action tools reject unavailable/locked rule storage and changed rules or assistant sessions. An agent must still obey its own permissions when performing external work.

## Example exchange

Ask without blocking:

```json
{"text":"Use the existing deck?","options":[{"id":"yes","label":"Use it","style":"primary"},{"id":"no","label":"Start fresh"}],"wait_seconds":0}
```

After the later delivery arrives, handle it, post the result with `zeus_present`, then acknowledge the actual received delivery ID:

```json
{
  "title": "Slides ready",
  "body": "The review deck is ready; add the final revenue figures on slide 7 before presenting.",
  "attachments": [{
    "kind": "file",
    "label": "Review slides",
    "target": "~/Assistant/review.pdf",
    "summary": "Twelve slides with updated charts and speaker notes. Slide 7 still has placeholders for the final revenue figures."
  }]
}
```

```json
{"delivery_ids":["d_example"]}
```

Replace the example path and ID with real values. The assistant should not repeat work when an already-handled delivery ID arrives again.

Sources: [base tool schemas](../Packages/ZeusKit/Sources/ZeusProtocol/ZeusMCP.swift), [app tools](../Packages/ZeusKit/Sources/ZeusProtocol/ZeusAppTools.swift), [rule tools](../Packages/ZeusKit/Sources/ZeusProtocol/ZeusRuleTools.swift), [tool handlers](../Zeus/Bridge/ZeusRuntime+Tools.swift), [attachment validation](../Zeus/Bridge/ToolArguments.swift), [app handlers](../Zeus/Bridge/ZeusRuntime+AppControl.swift), [journal handler](../Zeus/Bridge/ZeusRuntime+Journal.swift), [rule proposals](../Zeus/Bridge/ZeusRuntime+Learning.swift), and [rule actions](../Zeus/Bridge/ZeusRuntime+RuleActions.swift).
