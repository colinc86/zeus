# Zeus — Product Plan

Zeus is a desktop companion for macOS: a small animated pixel character that sits anywhere on screen and serves as the visible face of the user's personal-assistant agent. The agent (Claude Code, Codex, or OpenCode) does the thinking; Zeus is how it talks to the user, asks questions, hands over work products, and receives replies. An iOS companion app (over Tailscale) extends the same experience to the phone.

---

## 1. Goals

- **An always-present, low-friction face for the agent.** The user sees at a glance what the agent is doing (idle, thinking, working, has something, waiting on an answer) without opening a terminal.
- **Two-way, actionable interaction.** The agent can surface messages, questions, options, and real work products (files, folders, links, drafts), and the user can answer or act in one click.
- **Agent-agnostic.** Works with Claude Code, Codex, or OpenCode. The user picks which running session is "the assistant."
- **Agent as the brain.** Skills, crons, knowledge base, and other MCP tools are configured on the agent, not in Zeus. Zeus stays a thin, reliable interaction layer.
- **Seamless across devices.** The same cards and conversations appear on the Mac and the iPhone (via Tailscale), and an answer on either device is delivered once.

### Non-goals (for now)

- Zeus does not call model APIs directly. It talks to the user's existing **running terminal session**.
- Zeus does not schedule tasks or hold a knowledge base. That's the agent's job.
- No cloud backend. Everything is local or over the user's tailnet.

---

## 2. Example scenario

1. The agent's cron checks the user's tasks and meeting notes. It sees a presentation due in under 24 hours that hasn't been started.
2. The agent calls `zeus_ask`: *"Your talk on X is tomorrow at 10. Have you started on it?"* with options **Yes / No / Remind me later**.
3. The avatar animates to *alert*, and a speech-bubble card pops up. The user clicks **No**.
4. Zeus delivers the reply into the agent's running session. The agent answers with `zeus_say` (*"Okay, I'll take a first pass."*) and sets status to *working* with progress.
5. The avatar shows a working animation and a progress bar while the agent builds an outline and a Keynote draft.
6. The agent calls `zeus_present` with the outline summary and attachments **Open Keynote draft** and **Reveal in Finder**, plus actions **Looks good / Revise**.

---

## 3. Architecture

```
┌──────────────────────────── Mac ────────────────────────────┐
│                                                              │
│  Agent session (Claude Code / Codex / OpenCode, in terminal) │
│        │  stdio MCP                       ▲                  │
│        ▼                                  │ delivery         │
│   zeus-mcp (bridge, spawned per session)  │ (channel / tmux /│
│        │  unix socket (NDJSON)            │  OpenCode HTTP)  │
│        ▼                                  │                  │
│   Zeus.app ── cards, avatar state, routing ┘                 │
│        │                                                     │
│        └── Remote server (WebSocket, bound to tailnet) ──────┼──► iOS app
└──────────────────────────────────────────────────────────────┘
```

### 3.1 Two channels

MCP is request/response initiated by the agent, so Zeus needs two directions:

1. **Agent → Zeus (MCP tools).** The agent calls Zeus tools to show cards, ask questions, and set status.
2. **Zeus → Agent (delivery).** Two cases: the user answers later, or the user starts a conversation. Either way, Zeus must push text into the **already-running** session.

### 3.2 The `zeus-mcp` bridge

- A small stdio MCP server binary shipped inside `Zeus.app/Contents/MacOS/`. Each agent session spawns its own copy.
- It serves the tool list itself, so tools are visible even when the app is closed. It forwards tool calls to Zeus.app over a unix socket (`~/Library/Application Support/Zeus/bridge.sock`) using newline-delimited JSON.
- On connect it sends a `hello` with: agent kind, pid/ppid, cwd, MCP client name/version, and whether it supports channels. Zeus.app uses this to list **live sessions** the user can choose from.
- One bridge per session gives each session its own identity, so replies go back to **the session that asked**.

### 3.3 Delivery into a running session (per backend)

| Backend | Mechanism | Notes |
|---|---|---|
| **Claude Code** | **Channels**: the bridge declares `experimental: {"claude/channel": {}}` and emits `notifications/claude/channel` with `content` + `meta`. The message appears to the model as `<channel source="zeus" …>`. | Stdio only (hence the bridge). The session must be launched with `claude --dangerously-load-development-channels server:zeus` while channels are in research preview. `meta` keys must match `[A-Za-z0-9_]`. The bridge must negotiate an MCP protocol revision older than 2026-07-28 (or set `MCP_PROTOCOL_NEGOTIATION=legacy`). No delivery ack. Team/Enterprise orgs need `channelsEnabled`. |
| **OpenCode** | HTTP API of the running server: `POST /tui/append-prompt` + `POST /tui/submit-prompt` (drives the TUI), or `POST /session/:id/prompt_async`. | Verify the TUI endpoints against the live `/doc` OpenAPI spec. Supports basic auth via `OPENCODE_SERVER_PASSWORD`. |
| **Codex** | **tmux**: `tmux load-buffer` + `paste-buffer -p` (bracketed paste, safe for multi-line text), then `send-keys Enter` into the selected pane. | Codex has no documented push into an interactive TUI. The user runs Codex inside tmux and picks the pane. |
| **Any (fallback)** | **Polling**: undelivered replies and messages queue in Zeus, and the agent reads them with `zeus_get_responses`. | Also used whenever push delivery fails. |

tmux is also offered as a generic delivery method for any backend.

### 3.4 Asking questions without blocking forever

`zeus_ask` takes `wait_seconds` (default ~45s, max ~600s):
- If the user answers within the window, the answer is returned **as the tool result**.
- Otherwise the tool returns `{status: "pending", card_id}`. When the user answers later (hours later, or from the phone), Zeus delivers it into the session through the configured mechanism, e.g. `User answered card c_ab12 ("Have you started…?"): No, I haven't.`.
- Each response is delivered **exactly once**, either as a tool result, a push, or through `zeus_get_responses`.

### 3.5 Routing rules

- Replies to a card go to the **session that created it**, if it's still connected and push-capable.
- Otherwise, and for user-initiated messages, they go to the **designated assistant session** using the configured delivery method.
- If delivery fails, the message is queued for `zeus_get_responses`, and the avatar shows a subtle "couldn't reach agent" indicator.

---

## 4. MCP tool surface (v1)

| Tool | Purpose |
|---|---|
| `zeus_say` | Show a message card (markdown, optional title, mood, attachments, TTL). |
| `zeus_ask` | Ask a question with options and/or free-text input; blocking-with-timeout, then pending. |
| `zeus_present` | Rich content card: title, markdown body, attachments (file/folder/URL), action buttons. |
| `zeus_update_card` | Update a card's text/progress (for long-running work). |
| `zeus_dismiss` | Remove a card. |
| `zeus_set_status` | Set avatar state (`idle, talking, thinking, working, alert, waiting, happy, sleeping`), detail text, progress. |
| `zeus_get_responses` | Fetch undelivered replies and user messages (polling fallback). |
| `zeus_list_characters` / `zeus_set_character` | Let the agent change Zeus's costume. |

The MCP `instructions` field explains to the agent how to use these tools, what `<channel source="zeus">` events mean, and to reply via Zeus rather than only in the terminal.

### Card model (shared by Mac and iOS)

`Card { id, kind (message|question|content|progress|userMessage), title?, body (markdown), options[{id,label,style}], input?{placeholder,multiline}, attachments[{kind,label,target}], progress?, priority, mood?, sessionID?, createdAt, updatedAt, expiresAt?, status (open|answered|dismissed|expired), response?{optionID,optionLabel,text,respondedAt,device} }`

---

## 5. The avatar

### 5.1 Window behavior

- A borderless, transparent, non-activating `NSPanel` floats above other windows on all Spaces, including over full-screen apps. Drag it anywhere, and the position persists.
- Cards appear in a second panel anchored to the sprite: above it when there's room, otherwise below, clamped to the screen. It follows the sprite when dragged.
- Click the sprite to open the card stack, or a compose box when there are no cards. Right-click for a menu: Talk, Character, Settings, Hide, Quit.
- The app lives in the menu bar (no Dock icon). The menu bar item shows status, connected sessions, and settings.
- A badge shows the number of open cards.

### 5.2 Card UI

- A retro dialog-box style: dark panel, pixel-style border, monospaced headings, and a markdown body.
- Option buttons, a free-text field (single or multi-line), attachment rows (file icon, open / reveal in Finder), and a progress bar.
- Stacked cards with a pager ("1 of 3"); high-priority cards jump to the front.
- Later: typewriter text reveal and optional sound effects.

### 5.3 Sprite system (data-driven)

Characters are **JSON files**, not code, so new characters are easy to add. Built-ins ship in the app, and users can drop their own into `~/Library/Application Support/Zeus/Characters/` (same `id` overrides a built-in).

```jsonc
{
  "id": "ghost", "name": "Wisp", "width": 16, "height": 16,
  "palette":  { "k": "#2b2440", "w": "#f6f4ff", "l": "#d6d2f0" },   // '.' = transparent
  "palettes": { "fade": { "w": "#f6f4ffb0" } },                      // named overrides (flicker, glow, fade)
  "layers": {
    "body":  { "rows": ["....kkkk....", "..."] },
    "blink": { "x": 3, "y": 5, "rows": ["kk....kk"] }                // sparse, positioned overlays
  },
  "particles": {
    "wisps": { "colors": ["l","w"], "area": [2,14,12,2], "velocity": [0,-3], "spread": [1,1], "life": 1.2, "count": 3 }
  },
  "animations": {
    "idle": {
      "fps": 4,
      "motion": { "type": "float", "amplitude": 2, "period": 2.6 },
      "particles": ["wisps"],
      "frames": [
        ["body", "tailA", "face"],
        ["body", "tailB", "face"],
        { "layers": ["body", "tailA", "blink"], "palette": "fade", "hold": 1 },
        { "layers": ["body", { "layer": "face", "dy": 1 }], "dy": -2, "flipX": false }
      ]
    }
  }
}
```

What makes the characters feel alive, not static:
- **Layers + overlays**: a body plus sparse overlays (eyes, mouth, props) cut down on duplication. Blinks, talking mouths, and raised arms are just overlays.
- **Per-frame offsets and flips** for hops, squash and stretch, and hanging upside-down.
- **Palette swaps** for candle flicker, glowing orbs, lightning flashes, and semi-transparent fading.
- **Procedural motion**: float, bob/hop, shake, sway. Offsets snap to the pixel grid to stay authentic.
- **Deterministic particles** (sparks, embers, wisps, spores, bubbles). Each frame is a pure function of time, so there's no simulation state and iOS renders identically.
- **Emotes** drawn by the renderer for every character: thinking "…", alert "!", waiting "?", happy ♥, sleeping z's, working gear.
- **State fallback chain**: `working → thinking → idle`, `waiting → alert → idle`, everything else `→ idle`. A character only *needs* `idle`.

The renderer outputs an RGBA buffer and then a `CGImage`, drawn with nearest-neighbor scaling at a user-adjustable pixel scale. The same code runs on macOS and iOS.

### 5.4 Launch character roster (12)

| id | Character | Signature behavior |
|---|---|---|
| `zeus` | **Zeus**, the Greek god (default): white beard, laurel wreath, toga, standing on a cloud | Holds a crackling lightning bolt and raises it when alerting or working, with flash palette and sparks |
| `ghost` | Wisp, a ghost | Floats, wavy tail, fades semi-transparent while working, rising wisps |
| `pumpkin` | Jack, a jack-o'-lantern | Candle-flicker face glow, embers, hops when alerting, goes dark when sleeping |
| `hero` | Sprout, a green-tunic sword hero | Raises a gleaming sword, sword-swing frames while working |
| `wizard` | Merlo, a wizard | Pulsing staff orb, sparkle particles, staff raised while working |
| `robot` | Gizmo, a robot | Face screen shows loading dots when thinking and scrolling code when working; blinking antenna |
| `cat` | Midnight, a black cat | Swishing tail, glowing green eyes |
| `skeleton` | Bones, a skeleton | Chattering jaw when talking, glowing eye sockets, waves its arms |
| `slime` | Gloop, a slime | Squash-and-stretch hops, bubbles |
| `bat` | Nyx, a bat | Wing-flap cycle; hangs upside-down when sleeping |
| `owl` | Hoot, an owl | Big blinking eyes that look around while thinking, wing-spread when alerting |
| `mushroom` | Spore, a mushroom | Bouncing cap, drifting spores |

A dev tool (`zeus-sprites`) validates character files and renders a PNG contact sheet of every character × state for quick visual review.

---

## 6. Settings

- **Agent**
  - Backend: Claude Code / Codex / OpenCode.
  - Delivery method: defaults per backend (channel / tmux / OpenCode HTTP); polling is always the fallback.
  - **Assistant session picker**: live bridge connections (agent, cwd, connected since) for Claude; a tmux pane picker for Codex; server URL + session for OpenCode. The preferred working directory is remembered so the assistant re-binds after restarts.
  - Copyable setup commands, e.g. `claude mcp add zeus -- "/Applications/Zeus.app/Contents/MacOS/zeus-mcp" --agent claude`, the launch command with the channels flag, and the Codex/OpenCode equivalents.
  - A "Send test message" button.
- **Character**: an animated gallery with a state previewer, plus a pixel-scale slider.
- **Remote** (phase 3): tailnet server on/off, paired devices.
- **Debug**: demo cards (message, question, content, progress) for testing without an agent, plus a connection log.

---

## 7. Agent home (recommended setup)

A dedicated working directory (e.g. `~/Zeus/`) for the assistant session, containing a `CLAUDE.md` / `AGENTS.md` that defines:
- The persona (it *is* Zeus, the desktop companion).
- When and how to use the Zeus tools: proactive check-ins, asking before big actions, presenting work products as attachments, keeping status current.
- How to treat `<channel source="zeus">` events (user replies and messages) and to respond through Zeus.
- Etiquette: batch low-priority messages, respect sleeping/quiet hours, don't spam.

Crons, skills, the knowledge base, and other MCP tools are configured here by the user.

---

## 8. iOS companion (phase 3)

- The Mac app runs a **remote server** (WebSocket + small REST API) bound only to the Tailscale interface. Optionally it verifies peers with Tailscale's LocalAPI `whois`, plus a pairing token.
- The iOS app mirrors open cards, history, and avatar state (same sprites, same renderer) and lets the user answer cards and send messages. Responses carry `device: "ios"` and go through the same exactly-once routing.
- **Notification caveat:** without a push service (APNs requires a server or relay), the phone only gets real-time messages while the app is open or briefly backgrounded. Options to evaluate later: a minimal APNs relay, ntfy, or background refresh.

---

## 9. Security & privacy

- The unix socket is restricted to the user. The remote server listens only on the tailnet, with device pairing.
- Channel input is treated as user input. Only Zeus (an authenticated local app) can push into a session. The channel **permission relay** (approving tool use from the avatar) is deferred until sender authentication is in place.
- Attachments open only via `NSWorkspace`, and Zeus never executes agent-supplied commands.
- The app is not sandboxed, because it needs the unix socket, tmux, and file reveal. Revisit for distribution.

---

## 10. Tech stack

- macOS 26+, iOS 26+, Swift 6, SwiftUI with AppKit panels, Network.framework.
- Xcode project generated with **XcodeGen** (`project.yml`). The local Swift package **ZeusKit** contains:
  - `ZeusProtocol`: card model, avatar state, bridge wire protocol, MCP tool definitions, JSON utilities.
  - `ZeusSprites`: sprite format, renderer, character library and JSON assets.
  - `zeus-sprites`: validation and contact-sheet CLI.
- Targets: `Zeus` (menu-bar app) and `zeus-mcp` (command-line bridge, embedded in `Contents/MacOS`). Later: `ZeusiOS`.

---

## 11. Roadmap

### Phase 1 — Mac MVP
1. ZeusKit: protocol models, sprite format, renderer, 12 characters, validator and contact sheet.
2. `zeus-mcp` bridge: stdio MCP, tool list, socket link to the app, channel notifications.
3. Zeus.app: floating avatar, card panel, compose box, menu bar item, settings, demo cards.
4. Claude Code delivery via channels, end to end with the presentation scenario.

### Phase 2 — All backends & polish
5. tmux delivery (Codex and generic) and OpenCode HTTP delivery.
6. Card history and persistence, exactly-once delivery ledger, expiry.
7. Typewriter text, sounds, quiet hours/Do Not Disturb, launch at login.
8. Agent-home template and setup wizard.

### Phase 3 — iOS
9. Remote server over the tailnet, pairing, sync protocol.
10. iOS app: avatar, cards, compose, answers routed through the Mac.
11. Notification strategy (relay vs. foreground-only).

### Later ideas
- Permission relay: approve agent tool use from the avatar or phone.
- Custom character editor in-app.
- Multiple simultaneous avatars (one per agent/session).
- Voice input for replies.

---

## 12. Open questions

- Channels are a research preview, and the dev flag shows a confirmation dialog on every launch. Should we pursue publishing Zeus as a plugin so it can use `--channels plugin:zeus@…`?
- Codex: is tmux acceptable long-term, or should Zeus drive the Codex App Server directly (a different architecture: Zeus owns the session)?
- OpenCode: confirm that the `/tui/*` endpoints drive a TUI started with plain `opencode`, not just `opencode serve`.
- iOS push: is foreground-only OK for v1?

---

## 13. Decisions log

| Date | Decision |
|---|---|
| 2026-10-11 | **Delivery is at-least-once with dedupe.** The agent acknowledges with `zeus_ack` (or implicitly). Zeus redelivers unacked items with backoff. The ledger is persisted and is in Phase 1. See docs/CONTRACT.md §5. |
| 2026-10-11 | **Roster ships in tiers.** Zeus first, then the ghost, jack-o'-lantern and robot, then the remaining 8. |
| 2026-10-11 | **Avatar state is hybrid.** The app derives state from cards, explicit agent status overrides it (with a TTL), and new-card transients take priority (CONTRACT §7). |
| 2026-10-11 | **Card font is a setting.** Choices are a bundled OFL pixel font (default) or SF Mono. |
| 2026-10-11 | **Module split.** ZeusKit gains `ZeusLink` (socket server/client) and `ZeusDesign` (theme/components), both iOS-compatible. |
| 2026-10-11 | **Repo stays local** for now (no GitHub remote). |
| 2026-10-11 | **Conversation UX** replaces the card stack, after the human's first live test: one thread panel, an always-on composer, any option stays answerable, and composer text is a single reply (CONTRACT §10). |
| 2026-10-11 | **Orphaned replies reroute to the assistant.** The warning only shows for real failures. |
| 2026-10-11 | **iOS deferred** until the macOS app is squared away. |
| 2026-10-11 | **Pixel font is Departure Mono** (OFL), replacing Pixelify Sans, whose Z/2 and S/5 were confusable. SF Mono remains the alternative. |
| 2026-10-12 | **Zeus can manage its own assistant session** (the human's idea): folder, agent and launch prompt in Settings, run in tmux session `zeus`, MCP injected per launch. It becomes the primary onboarding path. TASKS Wave 9. |
| 2026-10-12 | **One managed session.** Its permission mode is the user's choice in Settings, listing each agent's own modes including auto/"yolo" (the human). |
