# Zeus — Engineering Contract (v1)

This file defines the interfaces **between** the team's areas. It lets designer, platform and appdev build in parallel. Inside your own area you have freedom. Anything listed here changes only with PM sign-off: propose the change in your hand-back and wait for approval.

Owners: §2–§5 platform · §6 designer · §7 appdev (consumer of all) · §8 designer + appdev.

---

## 1. Repository layout & module graph

```
project.yml                         XcodeGen spec (appdev)
Zeus/                               macOS app target (appdev; Zeus/Bridge + Zeus/Agents: platform)
Packages/ZeusKit/                   local Swift package (Package.swift: pm)
  Sources/ZeusProtocol/             models, wire protocol, MCP tool defs, paths          (platform)
  Sources/ZeusLink/                 NDJSON-over-unix-socket server + client               (platform)
  Sources/ZeusMCPCore/              stdio MCP server logic for the bridge (testable)      (platform)
  Sources/zeus-mcp/                 thin executable; the app embeds the built binary in Contents/MacOS (platform; embed: appdev)
  Sources/ZeusSprites/              sprite format, renderer, character library + JSON    (designer)
  Sources/ZeusDesign/               SwiftUI theme tokens, fonts, reusable styles         (designer)
  Sources/zeus-sprites/             CLI: validate characters, render contact sheets      (designer)
scripts/build.sh, scripts/test.sh   the definition of "it builds / tests pass"           (pm)
```

Dependencies:
- `ZeusLink` depends on `ZeusProtocol`.
- `ZeusSprites` depends on `ZeusProtocol`.
- `ZeusDesign` depends on `ZeusProtocol`.
- `ZeusMCPCore` depends on `ZeusProtocol` and `ZeusLink`. The `zeus-mcp` executable depends on `ZeusMCPCore`.
- `Zeus.app` depends on all four libraries.

No module depends on `Zeus.app`. Every library must stay iOS-compatible: no AppKit in ZeusProtocol, ZeusLink, ZeusSprites or ZeusDesign; use CoreGraphics and SwiftUI only.

---

## 2. ZeusProtocol — shared models

All types are `Codable, Sendable` and public. JSON uses camelCase keys and ISO-8601 dates. MCP tool arguments use snake_case (§4).

- **`JSONValue`**: a loose JSON enum (null, bool, number, string, array, object) with literal conformances, subscripting, and `decode(_:)` / `from(_:)` helpers.
- **`AvatarState`**: `idle, talking, thinking, working, alert, waiting, happy, sleeping`.
  - `fallback`: `working→thinking`, `waiting→alert`, `idle→nil`, and every other state `→idle`.
- **`AgentKind`**: `claude, codex, opencode, other`.
- **`Card`**:
  - `id` (`"c_"` followed by 8 chars)
  - `kind` (`message | question | content | progress | userMessage`)
  - `title?`
  - `body` (markdown)
  - `options: [CardOption]`
  - `input: InputSpec?`
  - `attachments: [Attachment]`
  - `progress: Double?` (0…1)
  - `priority` (`low | normal | high`)
  - `mood: AvatarState?`
  - `sessionKey: String?`: the session that created the card (§3.3)
  - `createdAt`, `updatedAt`, `expiresAt?`
  - `status` (`open | answered | dismissed | expired`)
  - `response: CardResponse?`
- **`CardOption`**: `{ id, label, style: primary | secondary | destructive }`.
- **`InputSpec`**: `{ placeholder?, multiline }`.
- **`Attachment`**: `{ id, kind: file | folder | url, label, target }`. For files, `target` is a path and `~` is allowed.
- **`CardResponse`**: `{ optionID?, optionLabel?, text?, skipped: Bool, respondedAt, device: "mac" | "ios" }`, plus `summary`. `skipped` defaults to false and a missing legacy field decodes as false; a skipped response has no `optionID` (TB1, 2026-10-14).
- **`Delivery`** (§5): `{ id ("d_"+8), kind: reply | userMessage, cardID?, sessionKey, content, meta: [String:String], createdAt, attempts, lastAttemptAt?, ackedAt?, failedAt? }`.
- **`ZeusPaths`**:
  - `appSupport` = `~/Library/Application Support/Zeus/`
  - `bridgeSocket` = `appSupport/bridge.sock`
  - `deliveries` = `appSupport/deliveries.json`
  - `cards` = `appSupport/cards.json`
  - `userCharacters` = `appSupport/Characters/`
  - Includes a helper that creates the directory.

---

## 3. App ↔ bridge wire protocol (ZeusLink)

### 3.1 Transport

- Unix domain socket at `ZeusPaths.bridgeSocket`, with permissions `0600`. The app listens, and each `zeus-mcp` process connects as a client.
- Framing is **NDJSON**: one JSON object per line, UTF-8, with the discriminator in the `"type"` field.
- `wireVersion = 1`. On a version mismatch, the app replies `{"type":"error"}` and closes the connection.

### 3.2 Messages

| Direction | `type` | Fields |
|---|---|---|
| bridge→app | `hello` | `wireVersion`, `bridgeID` (UUID generated per process), `agent: AgentKind`, `pid`, `ppid`, `cwd`, `client {name, version}` (from MCP initialize), `capabilities {channel: Bool, toolResultWritten?: Bool}`, `tmuxPane?` (from `$TMUX_PANE`), `tmuxSocketPath?` (socket path from `$TMUX`) |
| app→bridge | `welcome` | `wireVersion`, `sessionKey`, `appVersion`, `toolResultWritten?: Bool` |
| bridge→app | `toolCall` | `callID`, `name`, `arguments: JSONValue` |
| app→bridge | `toolResult` | `callID`, `text` (what the model sees), `structured?: JSONValue`, `isError` |
| app→bridge | `push` | `deliveryID`, `content`, `meta: [String:String]` |
| bridge→app | `pushWritten` | `deliveryID`. The notification reached stdout. This does **not** mean the model saw it. |
| app→bridge | `learning` | `id`, `kind` (`digest` or `moment`), `text` (§13). Sent only to bridges whose hello offered both `channel` and `learningNotifications`; no acknowledgment, and it never consumes unread state. |

| helper→app | `turnEnded` | `wireVersion`, `agent`, `pid`, `ppid`, `cwd`, `ancestors: [{pid, startTime}]`, `firedAt`, `reason: completed \| interrupted \| error \| sessionEnded \| idle`, `tmuxPane?`, `nativeSessionID?`, `deliveryID?` (SA3). Sent by `zeus-mcp` running as a launch-only hook (Claude `Stop` via `--settings`, Codex `notify`, OpenCode plugin) in a one-shot connection: no hello, no registration, no session replacement. `startTime` is the process start in µs; `firedAt` is Unix seconds captured before any I/O. |
| app→helper | `turnEndedReceipt` | `{}`. Acknowledges the callback only, never a model or delivery acknowledgment; best-effort and silent on failure. |

`capabilities.learningNotifications: Bool` is optional and defaults to false when absent; a new Claude bridge advertises it alongside `channel`, so old bridges never receive an unknown envelope. Wire version stays 1. `BridgeClient.start` takes an optional `onLearning` callback; learning and push callbacks run serially in wire order and must not await another tool result. Non-channel and legacy sessions obtain learnings by polling `zeus_get_learnings`.
| bridge→app | `toolResultWritten` | `callID`. The complete correlated MCP result was written and flushed to stdout. |
| either | `error` | `message` |

### 3.3 Session identity

- `bridgeID` identifies one bridge process and lives only as long as that process.
- **`sessionKey`** is the identity used for routing and rebinding: `"<agent>:<cwd>#<pid>.<start>"`. Here `<pid>` is the bridge's parent process, the agent session that launched it, and `<start>` is that process's start time, so a recycled PID never matches. The bridge reports both in `hello`; the app computes the key and returns it in `welcome`.
  - This works for every agent and terminal, and two concurrent sessions in one directory always get different keys (P13: three Claude sessions in one folder evicted each other in an endless reconnect loop).
  - The key lives exactly as long as the agent process. A restarted or `--resume`d agent is a new session; its old pending replies reroute to the assistant under §10.6.
  - Wire (§3.2): `hello` carries `ppid` and `parentStartTime` (µs since the epoch). The app sends `superseded {sessionKey}` to an evicted bridge before closing it.
- **Legacy keys** (0.1.0 format, with no `#pid.start`): pending *replies* reroute under §10.6. Pending *user messages* were always meant for "the assistant", so they're retargeted to the current assistant session when the app loads them.
- `tmuxPane` and `tmuxSocketPath` stay in `hello` as **delivery metadata only**, never identity. The socket is parsed from `$TMUX` by removing its final PID/index fields; commas in a socket path are retained. Pane IDs are scoped to this socket, including inspection, paste, Enter and cleanup. A live bridge that reports a pane without its socket queues with an upgrade explanation; Zeus never guesses the default server for it.
- When a session reconnects with the same `sessionKey`, it takes over any pending deliveries for that key.
- **Duplicates.** If two live bridges share a key, the newest one wins. The app tells the evicted bridge so explicitly (`superseded`), and that bridge **must not auto-reconnect**. It stays idle and tries again only when its own agent makes a tool call, so a flapping loop is impossible. A reconnect that carries the same `bridgeID` is the same bridge and never evicts anyone.

### 3.4 ZeusLink API (names fixed; platform chooses the internals)

```swift
public final class BridgeServer: Sendable {
    public init(socketPath: String, resultReceiptTimeout: Duration = .seconds(5))
    @MainActor public func start(delegate: any BridgeServerDelegate) throws
    public func stop()
}

@MainActor public protocol BridgeServerDelegate: AnyObject {
    func bridgeDidConnect(_ session: BridgeSession)
    func bridgeDidDisconnect(_ session: BridgeSession)
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult
    // Optional: a default no-op preserves existing delegates.
    func bridge(_ session: BridgeSession, finishedTool name: String, result: ToolResult, written: Bool)
}

public final class BridgeSession: Identifiable, Sendable {
    public let id: UUID            // bridgeID
    public let hello: BridgeHello
    public let sessionKey: String
    /// Resolves when the bridge reports pushWritten; throws on disconnect/timeout (5s).
    public func push(_ push: AgentPush) async throws
}

public final class BridgeClient: Sendable {
    public func requestTool(name: String, arguments: JSONValue = [:],
                            timeout: Duration = .seconds(610)) async throws -> BridgeToolResult
    public func reportToolResultWritten(callID: String) async throws
    // callTool consumes in process; the stdio server uses requestTool + receipt.
}
// BridgeToolResult contains callID and result: ToolResult.
```

**Result-consumption negotiation.** `hello.capabilities.toolResultWritten` and
`welcome.toolResultWritten` default false when absent; wireVersion stays 1. The helper
sends a receipt only when accepted by welcome, and only after MCP stdout write/flush.
The app commits polling acknowledgments or completes a synchronous-answer journal
entry on that receipt. Failure, disconnect or a five-second unconsumed-result lease
leaves input recoverable; a late receipt for an expired call cannot commit it. Legacy
peers commit at socket output, their strongest available boundary. Receipts are scoped
to a connection and callID; they prove transport consumption, never model reading.
Lost receipts may replay stable delivery IDs. Restart older helpers for stdout durability.

---

## 4. MCP surface (served by `zeus-mcp`)

- **Protocol version.** `zeus-mcp` speaks stdio JSON-RPC and **always answers `initialize` with protocolVersion `2025-06-18`**. Claude channels do not register on revision 2026-07-28 or later.
- **Capabilities.** It declares `tools: {}`. When `--agent claude` is set, it also declares `experimental: {"claude/channel": {}}`.
- **Instructions.** The `instructions` text lives in ZeusProtocol (`ZeusMCP.instructions`). It explains the tools, the `<channel source="zeus">` events, and the ack rule.
- **Tool list.** `zeus-mcp` answers `tools/list` locally from `ZeusMCP.tools`, so the tools appear even when the app isn't running.
- **App not running.** If the app is down, `tools/call` returns `isError: true` with the text: *"Zeus app isn't running — ask the user to open Zeus."*

Tool results are returned as `text` (compact JSON) plus `structuredContent`.

| Tool | Arguments (`*` = required) | Result |
|---|---|---|
| `zeus_say` | `text*`, `title`, `mood`, `attachments[{kind,label,target}]`, `priority`, `ttl_seconds` | `{card_id}` |
| `zeus_ask` | `text*`, `title`, `options[{id,label,style}]`, `allow_text` (default: true if no options), `placeholder`, `multiline`, `priority`, `wait_seconds` (default 45, clamped to 0…600) | `{status:"answered", card_id, option_id?, option_label?, text?}`, `{status:"skipped", card_id}` (the user skipped it: don't re-ask; proceed with your best judgement or move on) or `{status:"pending", card_id}`. Polled items (`zeus_get_responses`) carry `kind:"skipped"` for the same case. |
| `zeus_present` | `title*`, `body*`, `attachments`, `actions[{id,label,style}]`, `allow_text`, `mood`, `priority` | `{card_id}`. The chosen action comes back like a reply (§5). |
| `zeus_update_card` | `card_id*`, `title`, `text`, `append_text`, `progress` (0…1 or null) | `{ok}` |
| `zeus_dismiss` | `card_id*` | `{ok}` |
| `zeus_set_status` | `state*` (an AvatarState or `"auto"`), `detail`, `progress`, `ttl_seconds` (default 600) | `{ok}` |
| `zeus_get_responses` | — | `{items:[{delivery_id, kind, card_id?, option_id?, option_label?, text, created_at}], delivery_mode:"channel"|"tmux"|"opencode"|"polling", push_active:Bool}`. Metadata describes the calling session's current route/availability, not proof the model received input. Every returned item counts as **acked** at the result-consumption boundary (§3.4). |
| `zeus_ack` | `delivery_ids*: [string]` | `{acked:[…]}` |
| `zeus_list_characters` | — | `{current, characters:[{id,name,description}]}` |
| `zeus_set_character` | `id*` | `{ok}` |

---

## 5. Delivery semantics: at-least-once, deduplicated by ID

A **delivery** is any text Zeus sends *into* an agent session: either an answer to a card that the agent's `zeus_ask` call didn't wait for, or a message the user typed to the agent. All of this logic lives in the app (platform owns `Zeus/Agents/**`), and the state is persisted at `ZeusPaths.deliveries`.

1. **Synchronous answers.** If the user answers while a `zeus_ask` is still inside its `wait_seconds` window, the answer becomes the tool result; it is committed when the negotiated result-consumption receipt arrives (or at the legacy socket boundary). No `Delivery` record is created on the consumed synchronous path. A response intent journal is written before displaying the question; an unconsumed result is recovered into one durable reply with the same ID. Waiters and incoming responses are resolved on the MainActor, so each answer goes to exactly one path.
2. **Routing.**
   - A reply goes to the card's `sessionKey`.
   - A user message goes to the **assistant session** chosen in Settings.
   - **Admission (ST1, 2026-10-14).** Only the **assistant session** may create or change what the user sees (`zeus_say`, `zeus_ask`, `zeus_present`, `zeus_update_card`, `zeus_dismiss`, `zeus_set_status`, every app-control tool, `zeus_propose_rules`) or read Zeus state: the managed session when Zeus runs it, else the session picked in Settings › Assistant, else the session Auto adopted (the first channel-capable session of the chosen backend to connect, announced with "Talking to <agent> in <folder> · Change"; later sessions are never adopted on their own). Any other session gets `isError` with "Zeus only talks to its assistant. This session isn't it. Ask the user to pick this session in Zeus › Settings › Assistant, or stop calling Zeus tools."; nothing from it reaches the thread; at most once a day per refused session Zeus posts a quiet, badge-free line "Another session tried to reach Zeus: <agent> in <folder> · Make it my assistant · Ignore" (Open Settings instead of Make it my assistant while Zeus runs the assistant). Settings › Assistant › "Who may talk to Zeus": Only my assistant (default) / Any session with the Zeus server. Nothing is ever auto-accepted.
   - The connector follows the **effective delivery method**. For "Connect your own" that is the method selected in Settings: channel (only for a Claude bridge that supports channels; otherwise queued), tmux, OpenCode HTTP, or polling only. A Terminal pane the user picked is honoured even when the same session also offers a channel (CY1, 2026-10-14). For the managed session the runtime picks channel when the managed channel probe has succeeded and tmux otherwise, overriding the Settings value.
3. **Channel format.**
   - `content` is human-readable, e.g. `Reply to "Have you started on the presentation?": No, I haven't.` or `Message from the user: …`.
   - `meta = {kind, delivery_id, card_id?, option_id?}`. Keys must match `[A-Za-z0-9_]`.
   - A skipped question (TB1) is `content = The user skipped "<title>".` (the body stands in when there is no title), `meta.kind = "skipped"`, with `delivery_id` and `card_id` and no `option_id`.
   - A reflection (LM2, §13) is `meta.kind = "reflection"` with `delivery_id` and no `card_id`: a redacted local daily summary with outcomes, never a user request; the agent acks it after calling `zeus_get_rules` and, when useful, `zeus_propose_rules`. Text transports wrap it in the same envelope.
4. **Text delivery** (tmux / OpenCode). The envelope is:
   `[zeus delivery_id=d_… card_id=c_…] <content> (call zeus_ack with this delivery_id)`. A skipped question wraps the same sentence as the channel form.
   - The user's line breaks are kept (CRLF→LF, trailing whitespace trimmed); a single-line message is unchanged. Over tmux, multi-line text goes in as one owned **bracketed paste**, so a newline never submits early, followed by one Enter. Paste verification recognizes each agent's own rendering of our paste (including collapsed `[Pasted text …]` summaries) by the owned-paste journal and delivery ID, never by matching a user's draft.
   - **tmux:** use the target bridge's socket namespace and pane. Check the input before loading, immediately before pasting and after paste before Enter. Nonempty/unknown input remains saved; waiting for input or routing configuration does not consume the five-attempt budget. A detected human edit suppresses Enter and leaves the draft intact. The final snapshot→Enter step is not atomic in tmux; this remains a transport limitation.
   - **OpenCode:** `AgentRoutingSettings.openCodeSessionID(for:)` explicitly maps the Zeus process sessionKey to one native `ses…` ID. Validate `GET /session/{id}` and its exact directory. Never infer the native destination from cwd/history or inject into the global TUI draft. Missing/wrong selection queues input, with polling available.
   - POST the envelope as a text part to `/session/{id}/prompt_async`, scoped with `directory`. Use stable native message/part IDs derived from delivery ID, pinned destination and persisted ID time. Check `/session/{id}/message/{messageID}` before POST and after acceptance/lost results; require the matching user message and text part to be saved. Repair a partial save with the same identities, never append a second draft. Persist the validated native destination before POST; later Settings changes cannot retarget an uncertain accepted send. Dead-user-target/rerouted-reply binding clears the pin for the new destination. Authentication is read per attempt and never persisted in the delivery ledger.
   - OpenCode's shared folder MCP connection does not identify which native session made a tool call. Unmapped same-folder bridges are one Auto candidate; exact HTTP selections remain independent. Native-session selection is explicit, not a claim that Zeus can infer tool origin.
5. **Ack.** A delivery counts as acked when any of these happens:
   - `zeus_ack` includes its ID;
   - `zeus_get_responses` returns it and its result-consumption boundary (§3.4) commits;
   - any later tool call **from the target session** whose arguments include its `card_id`.
6. **Redelivery.**
   - If a delivery isn't acked after 3 minutes, Zeus sends it again, backing off 3 → 6 → 12 → 24 minutes.
   - After 5 attempts it is marked `failed`, the avatar shows a "couldn't reach agent" indicator, and the item stays available through `zeus_get_responses`.
   - Completion of a journaled tmux paste is a continuation of an existing submission: it bypasses `failedAt` and the five-attempt limit, does not increment `attempts`, sends only the verified existing paste once without repasting, and never relaxes destination, prompt or human-draft guards.
   - **Genuine human draft** (P2, 2026-10-14): when a queued message has waited 20 s behind the user's own unsent text in the managed pane, Zeus posts one alert card per draft episode ("Your assistant has unsent text in Terminal": the draft's first line, the queued count, **Open in Terminal**, **Cancel queued message(s)** with a confirmation when more than one). It resolves itself when the draft clears or the queue empties. Zeus never clears or submits the user's draft. Seam: optional `ManagedDraftAlertControlling` (`managedDraftStatusDetail`, `managedDraftCancellation`, `respondToDraftCancellation(id:confirmed:)`); the menu bar shows "Waiting on unsent text in Terminal".
   - If the target session is disconnected, the delivery waits. It is sent as soon as a bridge with that `sessionKey` reconnects.
   - The agent is told (in `instructions`) to ignore `delivery_id`s it has already handled.
7. **Restart safety.** Deliveries are saved to disk before the first send attempt and reloaded at launch.

---

**OpenCode destinations (R4b, 2026-10-13).** An explicit native session selection belongs to the server it was chosen on. Settings persist `OpenCodeDestination(sessionID:endpoint:)` (canonical endpoint) at selection time through the optional `OpenCodeDestinationRouting` capability; editing the server URL never rewrites saved selections. A selection or validated ledger pin whose endpoint differs from the current URL queues with a "choose again" reason and contacts neither server. Legacy ID-only selections and endpoint-less pins are never rebound to the current URL: they queue until reselected or discarded. Validated HTTP pins are excluded from dead-session retargeting, reply handoff and transport switching. Passwords stay per-attempt and never enter a pin.

## 6. ZeusSprites: renderer API (names fixed; designer owns the format)

- Characters are **JSON files**, one per character. They are bundled in `Sources/ZeusSprites/Characters/`, and users can add their own in `ZeusPaths.userCharacters`. A user file with the same `id` overrides the bundled one.
- Each character has its own pixel size.
- A character must define `idle`. Any state it doesn't define falls back through `AvatarState.fallback`.
- **The canvas size and anchor are constant per character, across all states and frames.** Padding covers motion, particles and emotes.
- **Rendering is a pure function of `(character, state, time)`.** There is no simulation state, so iOS renders identically.
- **State changes cut over on the next rendered frame.** There are no transitions in v1. If we add them later, the API gains `previous: AvatarState, since: TimeInterval`.

```swift
public struct SpriteCharacter: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public var canvasSize: PixelSize { get }   // constant per character
    public var anchor: PixelPoint { get }      // "feet" point; constant. y == canvasSize.height (feet line under the last row) is valid
    public var preferredScale: Int { get }     // points per pixel the character looks best at (from JSON, default 4)
}

public struct CharacterLibrary: Sendable {
    public static func load(userDirectory: URL?) -> CharacterLibrary
    public var characters: [SpriteCharacter] { get }
    public func character(id: String) -> SpriteCharacter?
    public var issues: [String] { get }        // validation problems found while loading (non-fatal)
}

public struct RenderOptions: Sendable { public var showEmote = true; public var reduceMotion = false }

public enum SpriteRenderer {
    public static func render(_ character: SpriteCharacter, state: AvatarState,
                              time: TimeInterval, options: RenderOptions = .init()) -> CGImage
}
```

The app draws the image at `character.preferredScale × sizeMultiplier` points per pixel. `sizeMultiplier` is a user setting: Small 0.75, Medium 1, Large 1.25. The result is rounded to whole points per pixel, minimum 2, with nearest-neighbor interpolation. It positions the panel so the canvas `anchor` stays fixed on screen.

---

## 7. Avatar state resolution (app)

The first rule that matches wins:

1. **Transient event.** For 2.5 seconds after a new card appears: the card's `mood`, or `talking` if it has none.
2. **Agent override.** An explicit `zeus_set_status` that hasn't expired yet (TTL). Sending `"auto"` clears it.
3. **Unseen cards.** At least one card the user hasn't seen yet → `alert`.
3b. **Assistant activity** (§10.8). `assistantActivity` is non-nil → `thinking` (or `working` when its phase is `.working`).
4. **Open question.** An open card is waiting on the user → `waiting`.
5. **Quiet hours** (Settings) → `sleeping`.
6. Otherwise, `idle`.

If cards are open, a badge shows the open-card count, whatever the state.

**Ghost mode** (Settings › Character, user decision 2026-10-13). When "Fade Zeus when idle" is on, the avatar window's alpha goes to the
chosen opacity (10–90 %) after the chosen delay (5 s – 10 min) with no interaction. It returns to full opacity, and the delay restarts, on:
pointer over the avatar, a click or drag, the Talk shortcut, a new card or peek, an open question, assistant activity, or the panel
opening. It never fades while the panel or a peek is showing, or while hidden. Faded Zeus still takes clicks (no click-through).
Reduce Motion removes the fade animation. `AvatarGhostState` is the pure reducer; the shell owns the timer.

**Panel width** (§10). The conversation panel is resizable by dragging its edge: minimum `ZeusTheme.Conversation.panelWidth` (today's
width), maximum half the screen, persisted in Settings and clamped on screen change. `ZeusBubble(maxWidth:)` follows it. Keyboard (A12): ⌘⌥← / ⌘⌥→ change the width by 20 pt from anywhere in the panel, ← / → do the same with the handle focused, and **Reset width** is in the panel and handle context menus and the handle's accessibility actions. All paths use the same clamp and persistence.

---

## 8. ZeusDesign: theme & components (designer delivers, appdev composes)

- Theme tokens: colors for light and dark, spacing, corner style, border width.
- **`ZeusFontChoice`**: `.pixel` (a bundled OFL pixel font, with its license file included) or `.system` (SF Mono). This is a user setting, and `.pixel` is the default.
- Components: `.zeusDialog(tail: ZeusDialogTail?, padding:)`, `ZeusButtonStyle(CardOption.Style)`, `ZeusTextFieldStyle`, `ZeusFieldChrome`, `ZeusProgressBar`, `ZeusAttachmentRow`, `ZeusBadge`, `ZeusPager`. `docs/design/CARDS.md` is the visual spec.
- The bundled pixel font is **Departure Mono** (OFL), chosen by the human on 2026-10-11 and replacing Pixelify Sans. Its license ships in the ZeusDesign resource bundle. The pixel role sizes sit on the font's 11 px/em grid: titles at 16.5 pt and every other role at 11 pt. Departure Mono has a single weight, so markdown **bold** in `.pixel` renders in the title accent color instead (D11).
- **Delivery failure in v1 is avatar-level only**, through `AvatarStatusControlling.setDeliveryProblem`. The runtime **shows** it when a delivery reaches `failed` (5 attempts) or when a user message has no reachable target. It **clears** it when every failed delivery has since been acked or returned by `zeus_get_responses`, or when the user dismisses the indicator. The text is `"Couldn't reach the agent. Saved for later."`. A per-card "couldn't reach the agent" note is deferred, because `Card` has no delivery state.
- `ZeusFonts.registerBundled()` registers the bundled font at launch.
- Must respect Reduce Motion and Reduce Transparency.
- Until ZeusDesign ships, appdev uses plain SwiftUI with `// TODO(ZeusDesign)` markers.

---

## 9. In-app seams (app UI ↔ runtime)

The protocols live in `Zeus/Shared/AppSeams.swift`, which the PM owns. That file is the source of truth for this section.

- **appdev implements**:
  - `CardStore: CardStoring`
  - `AvatarStatusModel: AvatarStatusControlling` (which also does the §7 resolution)
  - `CharacterControlling` and `AgentRoutingSettings` (both backed by settings)
  - `AgentRoutingSettings.openCodeSessionID(for:)` maps process keys to exact native sessions; its source-compatible default is nil.
- **Transport metadata:** `ConnectedSession.tmuxSocketPath` pairs with `tmuxPane`; its initializer defaults the socket to nil, preserving existing fakes/call sites.
- **platform implements** `@MainActor @Observable final class ZeusRuntime: AgentMessaging`, in `Zeus/Bridge` and `Zeus/Agents`:
  ```swift
  init(cards: any CardStoring, status: any AvatarStatusControlling,
       characters: any CharacterControlling, routing: any AgentRoutingSettings)
  func start() throws   // creates ZeusPaths dirs, loads the delivery ledger, starts BridgeServer
  func stop()
  ```
  The runtime owns the `BridgeServer` delegate, tool handling (§4 → the seams), `zeus_ask` waiters, the delivery ledger and redelivery (§5), and the connectors.
- **Composition.** appdev's app delegate creates the models, then `ZeusRuntime`, then calls `start()`. A start failure (for example, the socket is in use) appears in the menu bar status. The compose box and Settings depend only on `AgentMessaging`.
- **Responses.** The UI records responses only through `CardStore`. Routing happens only in the runtime, through `responseHandler`. No UI code talks to sessions directly.

---

## 10. Conversation model (v2 UX, decided 2026-10-11, replaces the card-stack UX)

Zeus is a **conversation**, not a stack of cards to clear.

1. **One conversation panel.**
   - Every click target in the conversation panel responds to the first click, whether or not the panel is key.
   - Clicking Zeus, or the global hotkey, toggles a single panel: a scrolling thread with the newest message at the bottom and a **composer that's always there**.
   - Agent cards render inline as message bubbles. Questions keep their option buttons live until answered, and content cards show attachments. A progress card updates in place, and a card dismissed by the agent fades to muted.
   - The user's own messages and answers appear as right-aligned bubbles.
   - Users never have to dismiss anything. Opening the panel marks everything visible as seen.
2. **Answers.**
   - Clicking an option on **any** open question, however old, answers that card. It routes exactly as today: CardStore → `responseHandler`.
   - Composer text is **one message**. The composer targets the **newest open question that accepts text**, even if a newer options-only question exists. It shows a "Replying to: <title>" chip, and sending answers that card. The user can press × on the chip, or Backspace in an empty field, to send a plain message instead. Otherwise it goes out as a user message (`sendUserMessage`).
   - With **no reachable assistant at all**, a composer message is **queued** rather than failed. The panel shows "Saved — I'll pass it on when your assistant connects", and it's delivered on connect or through `zeus_get_responses`.
   - **Durable outgoing lifecycle (UX-4).** Allocate `UserMessageDelivery.makeID()` once and persist that delivery ID beside the outgoing bubble before calling `AgentMessaging.sendUserMessage(_:deliveryID:)`. Reuse it after unsaved failures; an existing ID coalesces/observes saved work and cannot create a second message. Different text with the same ID fails. The legacy text-only send remains supported.
   - Observe `AgentMessaging.userMessageDeliveries` by ID on launch and after every change. States are `queued` (saved for transport/polling), `delivered` (actual transport receipt, awaiting ack), `acked` (scoped explicit/implicit ack or consumed polling result), and `discarded` (durable tombstone, never a model ack). A restored snapshot has `recovered: true` independently of its state. A transport attempt is not evidence of delivery; legacy snapshots without a receipt remain queued/unconfirmed.
   - The runtime publishes only committed snapshots. Unsaved failures are app-owned outgoing state, not a fabricated runtime queue. Missing IDs are unknown or pruned, never proof of ack; preserve the UI's persisted last-known state and do not automatically resend them. Persist lifecycle changes with the bubble so completed captions remain accurate after pruning. Keep every pending/unsaved outgoing bubble, plus the newest 500 history cards. Delivery history likewise keeps the newest 500 records plus pending items.
   - Discarded IDs are excluded from every send, retry, reroute, polling and ack path. Retry now resends only pending input. Private ledger version 2 reads version 1 and adds receipt/discard/state metadata; older apps reject version 2 rather than replaying discarded tombstones. Existing implementations retain source compatibility via a forwarding send default and an empty lifecycle snapshot default.
   - Several agent messages that arrive before the user replies still get a single reply. Nothing forces one answer per card.
3. **Badge and state.** The badge shows the unseen count. `alert` means unseen messages, and `waiting` means an open question. Both clear when the panel is opened, or once the question is answered.
4. **Keyboard.**

   | Key | Action |
   |---|---|
   | ⌥⌘Z (global, configurable) | Open the panel with the composer focused |
   | Return | Send |
   | ⇧Return | New line |
   | Esc | Close the panel and return focus to the previous app |
   | ⌘1–⌘9 | Pick an option on the newest open question or content card with actions (CONVERSATION.md is authoritative for shortcut details) |
   | ⌘, | Settings |
   | ⌘K | Clear the reply chip |
   | ↑ / ↓ | Scroll the thread when the composer is empty, or when the caret is on the composer's first or last line (otherwise they move the caret) |
   | Page Up / Page Down (fn↑ / fn↓) | Scroll the thread a page, always |
   | ⌘↑ / ⌘↓ | Jump to the oldest / latest message |

5. **One menu** (MB1, 2026-10-14). The menu bar icon and a right-click on Zeus show the same menu (`ZeusMenuModel`, built by `ShellController.menuModel`), top to bottom:
   1. status: the strip's sentence when a question or unread is waiting (choosing it opens the panel at that message), else the avatar status; the managed actions or the Assistant session picker; unread, issue and "Hidden until" lines;
   2. Talk to Zeus… · Ask About This (LM2-B: Shift + the Talk shortcut when that combination registered, otherwise the menu item only; it opens the composer with the current level 2 record and, with level 3 on, one redacted frame as removable chips; nothing is sent before Send) · Hide/Show Zeus · Hide for 1 Hour · Hide Until Tomorrow · Delivery problem… (only when there is one);
   3. Character ▸ · Size ▸ · Theme ▸;
   4. Settings… · Check for Updates… · About Zeus;
   5. Quit Zeus.
   The menu bar icon can be turned off (Settings › General › Show menu bar icon, default on). There is always an entry point: turning the icon off while Zeus is hidden shows Zeus first; reopening the app shows Zeus, clears a timed hide and opens the conversation (or Settings); the Talk shortcut works either way.
6. **Delivery warning (amends §5 and §8).**
   - If a reply's target session has been disconnected for more than 60 s, the reply is **rerouted to the assistant session**, with the prefix `(Answer to a question from an earlier session)`.
   - The avatar warning shows **only** when a delivery reaches `failed`, or when items have been pending for more than 2 minutes with no reachable session at all.
   - Clicking the warning opens a small popover that explains it, with **Retry Now** and **Discard…** buttons.

6b. **Typewriter plays once per card, ever.** It runs only when a card first arrives, either in a peek bubble or while the panel is open and that card is visible. A card shown in a bubble doesn't type out again in the panel. Scrolling, reopening the panel, relaunching or re-rendering always shows the full text immediately. Revealed state lives in the model (persisted with seen state), never in view `@State`.

7. **Peek bubble** (the human's request, 2026-10-11). This is what Zeus does when a message arrives and the panel is **closed**.
   - **What triggers it.** A new agent card of kind `message`, `question` or `content` pops a small speech bubble from Zeus: the title and the body, **sized to fit the text exactly**, up to 6 body lines. Longer bodies end that last line with "…" and a "More" link that expands the panel. The bubble never clips a glyph (2026-10-12 feedback), with a typewriter reveal. **The card is added to the conversation thread either way.** The bubble never takes focus. Progress updates, status changes and agent-side updates to existing cards **don't** pop a bubble.
   - **Expanding.** Clicking the bubble, or pressing the global ⌥⌘Z, opens the conversation panel scrolled to that message, with the composer focused.
   - **Questions.** The bubble shows up to 3 option buttons; clicking one answers the card directly, with no expansion. A question with more than 3 options, or one that only takes text, shows "Reply…", which expands the panel.
   - **Several arrivals.** The bubble shows the newest card with a "+N more" tag, never a stack of bubbles.
   - **Auto-hide.** It hides after `clamp(4 + words/4, 6, 15)` seconds and pauses while the mouse is over it. It has an × to close it. `high` priority cards stay until the user interacts.
   - **Quiet hours, hidden avatar, Do Not Disturb.** No bubble, only the badge (and the menu bar dot).
   - **Seen.** A card shown in a bubble counts as seen only once the user interacts with the bubble or opens the panel. Otherwise it stays unseen, so the badge and `alert` remain.
   - **Placement.** Anchored to Zeus like the panel: above or beside Zeus, with a tail, clamped to the screen, following drags.

8. **Activity indicator and auto-scroll** (the human's request, 2026-10-12).
   - **What it shows.** While an agent is producing a response, the thread shows an indeterminate pixel "typing" row at the bottom on the agent's side. It carries `detail` text and a thin progress bar when the agent provides them. When the panel is closed, there's no bubble; the avatar's `thinking`/`working` state (§7 rule 3b) conveys it.
   - **Seam.** `AgentMessaging.assistantActivity: AssistantActivity?` (AppSeams.swift). Platform computes it; appdev renders it.
   - **Phases.**
     - `.sent`: a user message or a card answer was delivered (channel push written, tmux/OpenCode injected, or a synchronous `zeus_ask` result returned) to a session.
     - `.thinking`: that session has shown activity since: an ack, or any Zeus tool call.
     - `.working`: that session called `zeus_set_status` with `thinking` or `working`. The detail and progress come from that call. This applies even when no user message started it (unsolicited work).
   - **Ends when** the session posts a new card (`zeus_say` / `zeus_ask` / `zeus_present`), calls `zeus_set_status` with `auto` or any other state, the override TTL expires, the session disconnects, or the delivery is discarded. For the **managed session** it also ends when a positive idle screen follows a working screen, or 20 s after the row started (an agent that ends its turn without `zeus_say` must not keep Zeus thinking; 2026-10-14). A short turn can begin and end between screen samples, so a fresh **native completion** also ends it early: for Claude, a new "✻ … · done" footer scoped to the user prompt that started this response (never a scheduled-task footer); for Codex and OpenCode, the native completion line following the history echo of this exact delivery ID. Repainted old footers, a new user echo and unsent composer text are not completion. Explicit `working` statuses keep their TTL regardless of screen evidence (SA1/SA2, 2026-10-14). A `turnEnded` wire message (§3, SA3) from a hook Zeus added at launch ends only the implicit `.sent`/`.thinking` response whose input began by `firedAt` and whose optional delivery ID matches, for the session whose agent and exactly one registered parent process lifetime match the bounded ancestry (never cwd or pane alone; a known OpenCode destination must agree on the native ID). A changed response token, a runtime restart or an explicit `working` status invalidates it; a correlated early connector or answer receipt is tombstoned so a fast completion is never resurrected, while newer in-flight input keeps its own receipt. Launches without the hook keep the screen and stale rules. An interruption by Escape in the terminal emits no hook from Claude Code; it falls back to those rules (decided 2026-10-14). The same screen rules extend to a **Connect-your-own** assistant using "Its Terminal pane" (SA4) only when the user explicitly selected that pane and its socket matches the registered session: Zeus captures it read-only every 3 s only while that session has an implicit `.sent`/`.thinking` activity, and stops on completion, a selection or mode change, disconnect or runtime shutdown; pane, server and agent lifetimes are validated around each capture and the session, destination, generation and response token are revalidated after every await. For an own Claude session without a pre-response sample, completion requires the current delivery envelope in the history, never an old footer. An ended source cannot revive; a newer in-flight transport receipt may still start its own response. Own-session sampling never mirrors prompts, alerts on drafts or creates blocked cards (those stay managed-only). Sessions without a selected pane keep the hook and stale rules. It also ends after **5 minutes with no activity** from that session (`.sent` and `.thinking` only; `.working` follows its TTL). Only a newly delivered message or answer, or an explicit `zeus_set_status` with `thinking`/`working`, starts it again. Acks and other tool calls only advance a row that already exists (`.sent` → `.thinking`); they never create one (P12).
   - **Several sessions.** One indicator: the most recently started activity wins.
   - **Agent instructions.** `ZeusMCP.instructions` and the assistant template (`Zeus/Resources/AssistantTemplate`) tell the agent that Zeus shows "thinking" automatically after a message, and that if it finishes **without** posting to Zeus, it should call `zeus_set_status {"state":"auto"}` to clear it.
   - **Auto-scroll.** When a new message or typing row appears, or a typewriter grows, the thread follows it, **but never scrolls past the point where the newest message's top reaches the top of the viewport**. A long message is read from its top, not its bottom. Auto-scroll only happens while the user is "at the bottom" (within ~1 line of it, or already pinned to the newest message's top). If they've scrolled up to read history, the thread doesn't move; a small "↓ New message" pill appears, and clicking it or pressing ⌘↓ jumps there (with the same top-of-message cap).


## 11. Managed assistant session (Wave 9, decided 2026-10-12)

Zeus can launch and keep alive **one** assistant session of its own. Connecting an existing session (§3) remains the advanced path. While a managed session is enabled, it **is** the assistant: routing pins `assistantSessionKey` to it.

1. **Configuration** (Settings, backed by appdev; seam `AgentRoutingSettings.managedSession`): enabled, folder (absolute), agent (Claude Code / Codex / OpenCode), permission mode, launch prompt, and "Start when Zeus opens" (default on once configured).
   - **Launch prompt** is one user-editable text with a good default (designer writes it). It's passed as **additional instructions on every launch** (Claude `--append-system-prompt`, Codex `-c developer_instructions=…`, OpenCode an app-owned `instructions` file). A fresh conversation also gets a short fixed first message from Zeus asking the agent to check in with `zeus_say`. Edits apply to the next **new** conversation; Settings says so and offers "Start a new conversation".
   - **Permission mode** lists the selected agent's own modes (platform supplies them: `permissionModes(for:)`), including its full-auto / "yolo" mode, which is labeled as unrestricted. Default: the agent's normal, asking mode (Claude `default`/manual, Codex `on-request` approvals with `workspace-write`, OpenCode `ask`).
2. **The user's own setup is kept.** Zeus is **added** for that launch only: no `--strict-mcp-config`, no `--setting-sources ''`, no `--pure`. The user's settings, MCP servers, plugins, permission rules and CLAUDE.md/AGENTS.md all still apply. Zeus never edits agent config files and never answers a trust, login or permission prompt on its own (item 5 covers the user answering from the chat).
3. **tmux.** Use the user's **default** tmux server, with absolute executable paths, inherited client `TMUX`/`TMUX_PANE` cleared, and explicit UTF-8 locale and PATH for the child. The session is named `zeus`. If a session with that name exists and isn't ours, use `zeus-2`, `zeus-3`, …. Ownership is a session user option `@zeus-owner <token>`, and targets use `=name` and pane IDs. The window has `remain-on-exit on` set before the agent starts; global options are never changed. The agent is the pane's process (`respawn-pane` with argv; no shell wrapper), so the pane PID equals the bridge's parent PID, and the managed session's `sessionKey` (§3.3) is known exactly. Settings and the menu show the session name, `tmux attach -t <name>` with Copy, and **Open in Terminal**.
4. **Lifecycle.**
   - Persist the agent's **native conversation ID** (Claude: preassigned `--session-id`; Codex thread ID; OpenCode `ses_…`). Restarts **resume** it and omit the first message.
   - **Unexpected exit** (signal or nonzero status): restart with backoff of 2 s, 10 s, 60 s, then `failed` after 5 restarts in 10 minutes. A **clean exit** (status 0, e.g. the user typed `/exit`) means `stopped`; there's no auto-restart.
   - **Quitting Zeus leaves the agent running.** On launch, Zeus adopts a live owned session instead of starting another.
   - Stop sends the agent's own exit and then, after a timeout, kills **only the managed pane** (verified by its PID and start time). Panes the human added to the window or session are theirs: Zeus never kills them. It removes the window only when the managed pane was its last pane. After Stop, Zeus releases its lease on any remaining panes; a later Start launches a new managed window (in the owned session if it still exists) and never adopts a pane it didn't launch. (A3-2, 2026-10-13) "Start a new conversation" stops, discards the stored conversation ID and starts fresh.
5. **Blocked detection.** Sample the visible pane (`capture-pane`, no scrollback) plus `pane_dead*` metadata, every 3 s while running, and only for the managed pane.
   - **Precedence:** dead or missing → login, onboarding, trust or permission dialog → working → probably idle → unknown.
   - **Debounce:** a 10 s startup grace, and 2 consecutive matching samples before reporting `blocked`.
   - **Blocked** posts one `high`-priority card from the managed session: "<Agent> is waiting for you in Terminal". Its body is the dialog's first lines, and it carries an **Open in Terminal** action. The avatar shows `alert`. The card resolves itself when the block clears.
   - **Answering from the chat** (user decision 2026-10-13). When a permission prompt parses into a `ManagedAgentPrompt` (kind, title, clean detail, question, the agent's own options in order, fingerprint), the card shows the question and one button per option, plus **Open in Terminal**. A click calls `answerManagedPrompt(fingerprint:optionID:)`: Zeus re-captures the pane and sends that option's own selection key only if the same prompt (fingerprint) is still showing and the option is still listed in the same live pane; otherwise it sends nothing and says the question changed. Results: answered, changed or unconfirmed. Never a default, a timer, an autonomous answer or free text ("Tab to amend" stays in Terminal). Unparseable prompts keep the Terminal-only card.
   - **Never type into a blocked pane** other than that one validated choice key. User messages queue until it's idle.
   - Unknown is not idle. Quiet is not dead.
6. **Delivery to the managed session.**
   - **Codex and OpenCode:** tmux into the managed pane, with §5.4's draft and socket guards.
   - **Claude:** channel push **only after channel readiness is confirmed**, meaning the session has acked a pushed item. Until then, and whenever a push isn't acked within 30 s, use tmux paste into the managed pane. The pane is the authoritative fallback because Zeus owns it.
7. **State seam.** `ManagedSessionControlling` exposes:
   - `status`: off, starting, running(idle/working/unknown), blocked(reason), stopped, restarting(at), failed(reason);
   - the actual tmux session name and attach command;
   - start, stop, restart, start-new-conversation, open-in-terminal, and `permissionModes(for:)`;
   - optionally `ManagedPromptAnswering`: `managedPrompt` and `answerManagedPrompt(fingerprint:optionID:)` (item 5).
   - optionally `ManagedSettingsApplying` (user decision 2026-10-13: Settings changes apply to the running session):
     `managedAppliedConfiguration`, `managedSettingsApplication` (phase waiting/applying), `managedCanResumeSettings`,
     `supportsInstructionChangesOnResume(for:)`, `applyManagedSettings(_:)`, `switchManagedSettings(_:)`, `cancelManagedSettingsApplication()`.
     **Permission mode and Instructions** apply automatically by restart-with-resume (same conversation, native ID kept), only when the
     pane is positively idle with an empty composer, not blocked, not answering a prompt, no delivery in flight; otherwise the request
     waits (Settings shows the pending note) and the latest edit replaces an earlier waiting one. Instructions are debounced (typing
     pause or leaving the field). Agents that can't take new instructions on resume (Codex today) get an honest caption: they apply to the
     next new conversation. Claude needs `--system-prompt-snapshot off`, used only when the installed CLI advertises it.
     **Agent or folder** can't move a conversation: Settings asks once ("Switch Now" / "Later", Later focused, Esc = Later); Switch Now
     stops the old session at a safe moment and starts one new conversation. Settings that don't affect the session (Start when Zeus
     opens) never restart. Unrestricted modes keep their confirmation.

   Platform implements it in the runtime; appdev renders it in Settings, the menu and first run. The menu bar shows a status line for every state (MANAGED.md §4), and an alert icon for blocked and failed.
- **Setup freshness (LM4).** Optional `LearningDeliveryPresenting` exposes `managedSetupStale` (tools, template, templateEdited), pending learning/reflection snapshots, and delivery holds. The managed lease records the canonical tool-list hash and shipped template version at successful launch; adopting an older live pane never upgrades that evidence. Setup Restart uses the existing safe settings-apply/resume path and its waiting/applying/error state. Launch/restart refreshes AGENTS.md and CLAUDE.md only when their exact bytes match a shipped version. User edits, unknown files and symlinks are preserved; explicit replacement requires confirmation of an unchanged folder/file-hash snapshot. No other folder files are touched.

8. **Requirements.** tmux and the chosen agent CLI must be installed; Settings detects both, with a one-line install hint when missing. The agent must already be logged in; a login screen is just a blocked state (item 5).
9. **Agent updates** (UP1, 2026-10-14). When the agent's own TUI shows an installed update waiting for a restart (Claude: "Update installed · Restart to update" in the composer chrome), `ManagedSessionController` publishes `managedAgentUpdatePending` after two consecutive samples and clears it after one sample without it or after a restart. Zeus posts one quiet thread notice per conversation nonce, "<Agent> has an update · Restart assistant", never a peek or badge, never while a question is pending. The action requests a safe-moment restart through the settings-apply path (item 7): it waits until the assistant is idle with nothing in flight, then restarts the same conversation with the agent's resume so context is kept; unrestricted modes keep their confirmation. The request carries a UUID so a completed restart is reported once and honestly; dismissal survives history clearing. Settings › Assistant shows the same state with one Restart button. Nothing restarts without a click.

---

## 12. The assistant controls the app (decided 2026-10-13)

**Rule.** The assistant may change anything the user could change in Settings or by clicking Zeus **that does not affect the assistant's own authority**. Every change appears in the conversation as one line with a single undo action.

**Tools** (all on `zeus-mcp`, same session scoping as §4): `zeus_app_state`, `zeus_set_character`, `zeus_create_character`, `zeus_set_theme`, `zeus_create_theme`, `zeus_move`, `zeus_set_size`, `zeus_hide`, `zeus_set_appearance`, `zeus_check_for_updates`, `zeus_install_update`. Their arguments mirror `AppControlling` in `Zeus/Shared/AppSeams.swift`, which is the source of truth for this section, and `ZeusMCP.tools` carries their schemas.

**Never** (enforced in the runtime): answering, dismissing or pre-selecting any prompt; changing its own permission mode, instructions, agent, folder or run mode; starting, stopping or restarting its own session; clearing the conversation; turning on launch at login, "learn from me" or automatic update checks; reading or changing another session's state; touching the user's agent configuration. These have no tools; the runtime also rejects `zeus_set_appearance` patches that switch quiet hours off while a question is pending. Rejections return `isError` with the rule named and post nothing to the chat.

**Switches.** Settings › General: "Let my assistant control Zeus" (default on; off makes every mutating tool return `disabled`) and "Let my assistant install updates" (default on).

**Updates.** `zeus_install_update` needs a prior `zeus_check_for_updates` that reported that version. The runtime posts "Updating to X — back in a few seconds", waits until no delivery is in flight and the assistant is not blocked, then calls `installUpdate`. The managed tmux session survives the relaunch; on relaunch Zeus reconnects to it as after a normal restart.

**Undo.** `CardStoring.recordAppChange` adds a `.appChange` thread item: the summary and one button (`Undo`, or `Show now` for a hide) that runs the change's `undo` closure once and then shows as done. Creating a character or theme and undoing it switches back but keeps the file. Undo is local; nothing is sent to the assistant.

**Arguments and results.** Creation tools take `name` and `json`, where `json` is complete UTF-8 JSON file text validated by the app's real loader. `zeus_move.position` is a named placement or `{screen, x, y}` in screen points. `zeus_hide` requires exactly one of integer `minutes` (1–720) or `until: "tomorrow"`. Appearance argument names are the snake_case equivalents of `AppearancePatch`; omitted fields are unchanged. Unknown arguments are rejected. Turning quiet hours off is rejected while any open Zeus question exists, without revealing the question's content or creator. State and update-check results use their seam types' Codable fields. `AppChange`-returning mutators return `{ok: true, summary}`; `zeus_set_character` keeps `{ok, previous, current}`. `AppControlError` file, argument and updater messages are returned verbatim as the compact JSON result's `error` value with `isError`. Validation failures post no chat line. Update checks are gated by the master switch too.

**Update flow, precisely.** Each session must have seen the exact version in its own successful `zeus_check_for_updates`. Installation announces "Updating to X — back in a few seconds", then waits for that session's other in-flight Zeus tool calls, waiting asks, transport sends and journaled pastes, and for the managed session's blocking prompt to clear. After 60 seconds it proceeds anyway, provided the runtime is still active and both control switches remain enabled. Installation is irreversible: its announcement is the history line, and there is no Undo. If installation fails after the announcement, the reason is added to the calling session's thread, returned by this call, and returned once more by that session's next tool call; other sessions never receive it.

**Card ownership.** Card update and dismiss tools cannot reach another session's card or change local native-prompt or Terminal notices. An explicit delivery-ledger handoff lets the receiving session update its earlier session's card, preserving §4's rerouting.

**Instructions** (AssistantTemplate and `ZeusMCP.instructions`): change the look only when the user asks or for something you just made at their request; prefer `near-active-window` over coordinates; don't move Zeus while the user is typing to it; read the formats from `zeus_app_state.formats` before writing a character or theme; install an update only when the user asks or told you to keep Zeus current.

---

## 13. Learn from me, level 1 (decided 2026-10-13)

**Scope.** Off by default. When on, Zeus records on this Mac: frontmost-app changes (bundle id, name, time), app launches and quits, unlock/lock/sleep/wake, idle periods of 5 minutes or more, and display count. Never keystrokes, clipboard, window titles, URLs, file names, screenshots, audio or location. No macOS permission is needed.

**Store.** `~/Library/Application Support/Zeus/Activity/<yyyy-mm-dd>.jsonl`, mode 0600. Raw events kept 90 days by default (Settings: 7–90); digests kept one year. Excluded apps (default: password managers, Keychain Access, Passwords, System Settings; user-editable) are recorded as `private` with a duration and no name.

**What the assistant receives.** Never raw events. A morning digest (about ten lines summarizing the previous day, sent at the first activity of a new day) and at most four "moments" a day from the kinds the user ticked: first activity, back from a break of 2 h+, unusually late start, day winding down. Delivered as an MCP notification plus `zeus_get_learnings` (returns the digests and moments not yet read, newest last). Each send adds a quiet thread line "Sent your daily summary · View" that shows the exact text.

**UI.** Settings › Privacy: the switch (with a one-time sheet listing the scope and the caveat), "What Zeus has recorded" (today's list), Pause for today, Delete everything, the excluded-apps list, retention. Caption: "Summaries go to your assistant, which sends them to its model provider like any message. Raw activity never leaves this Mac."

**Seams.** `LearningsProviding` (the app's `LearningsStore` implements it, the runtime reads it): `unreadLearnings()`, `markLearningsRead(through:)` and the `onNewLearning` callback the runtime turns into the notification. The runtime owns `onNewLearning` while started and releases it at stop. The store owns the quiet "Sent your daily summary · View" thread line.

**Levels 2–4 and rules (LM2, decided 2026-10-14).** The seams live in `Zeus/Learn/Seams.swift` (platform-owned; this section names them). `Redactor` turns any observation into a `Redacted<T>` before storage, by construction: stage 1 patterns, `NSDataDetector` and `NLTagger` always; stage 2 the on-device Foundation Model for prose, with `RedactionReport.semanticEngine` recording which engine ran (`onDeviceModel`, `naturalLanguage`, `patternsOnly`). Kinds: `email, phone, card, iban, identity, secret, address, name, health, finance` → typed placeholders. `JournalStore` keeps `JournalItem`s (`JournalLevel` 1 activity, 2 focus, 3 screen, 4 typed; `JournalKind` activity, focus, description, frame, typedText, outcome, reflection, sentToAssistant) per day, encrypted with a key in the keychain, with `JournalRetention` per level and `JournalDeletion` by item, day, app or all; the L1 activity store migrates into it. Capture at any level needs the level's explicit consent plus its macOS permission, honours the per-level coin (deny list or allow list) and the hard stops (private list, private windows, secure input, lock); Safari is app-only unless allow-listed. `RulesStore` keeps `LearnedRule`s (`kind` passive | acts; `status` active | proposed | shadow | retired; `confidence`; evidence item ids; `author` agent | user) and `RuleOutcome`s (accepted, skipped, undone, ignored, toggledOff, toggledOn, edited) that move confidence; rules below the floor retire. The dial (Ask me first · Balanced · Just do it) sets what new rules do and is never a permissions bypass. Tools: `zeus_get_rules` (active and shadow) and `zeus_propose_rules {rules[]}` (passive → active with a quiet "New rule · Review" line; acts → shadow with "I'd have … · OK next time?"). A **reflection** is a delivery of kind `reflection` (§5) sent at most once a day at the first long idle after the day ends: a redacted local summary plus outcomes, never a user request; the agent reads rules, proposes only useful supported rules, and acks. An active passive rule with an evaluable trigger **holds** non-urgent notifications (no peek, no sound; the badge and thread stay), `high` priority bypasses, and clearing the trigger replays only the newest still-unread eligible card through the normal visibility and quiet checks (§7/§10). The **Sent ledger** records exact redacted outgoing text with path-free recipient identity for writes that were consumed, never attempts.

**Level 3, screen (LM2-B, 2026-10-14).** Capture is of the front window only, through a desktop-independent window filter, never a display, at a preview whose longest side is at most 1280; the foreground process and window are checked again after content discovery and before storage. Triggers: an app or document switch after 10 s of dwell, 5 min in the same context, return from idle, and on demand; an unchanged frame (64×40 dHash and diff) is not stored; the per-hour cap defaults to 12. Hard stops before capture and again before storage: camera in use, display mirroring or a presentation playing, secure input, a private browser window, a private-list app, the screen locked. Browser privacy is `normal`, `private` or `unknown`, bound to the capture identity (bundle, PID, window); unknown browsers fail closed even when allow-listed; Safari is captured only when allow-listed for level 3, with the note that private windows cannot be told apart. Every frame passes the frame redactor (OCR → `Redactor` → text regions covered with solid boxes, pictures over 48×48 px pixellated, faces pixellated; the user copy says "covered" and "pixellated"; password dialogs, Keychain and banking bundle ids dropped) and is stored encrypted with its boxes and `RedactionReport`; the on-device model writes the `description` item from OCR text and metadata, with an `NLTagger` fallback. Retention: frames 7 days fixed; descriptions 7/30/90, default 90. Summaries and reflections carry sampled descriptions, never frames. Deleting a frame is one action with Undo.

**Level 4, typing (LM2-C, 2026-10-14).** A listen-only key-down event tap, translated for the active layout with dead keys preserved across idle boundaries, groups keys into runs per app and window (a run ends after 2 s or a focus change; Backspace edits it). Guards before every key and again before storage: Input Monitoring granted (revocation stops the tap and the journal notes it; stale grant evidence is cleared), `IsSecureEventInputEnabled()` false (a password field turns it on at focus, so no password character ever reaches the tap), not a private browser window, not a private-list app, screen unlocked, the level 4 coin and lists. ⌘V or a pasteboard change count marks `‹pasted›` without reading the pasteboard; menu-bar Paste and drag-drop produce no keys. Every completed run passes the `Redactor` (mandatory; a run that is wholly a secret pattern is dropped; runs under 3 words keep only a topic); the on-device model writes a one-line topic (app, intent, subject, recipients as roles, never names) with an `NLTagger` fallback. Storage splits: words 0 / 24 h (default) / 7 d; topics 7 / 30 (default) / 90 d; deletion by typing group is atomic with Undo. Summaries and reflections carry topics only, never words. The menu shows "Private input: Zeus isn't noting typing" while secure input is on and level 4 is enabled.

**Phase D, depth (LM2-D, 2026-10-15).** `zeus_get_journal {query, from?, to?, kinds?, raw?, limit?}` answers from the journal with redacted summaries, descriptions and topics (default the last day and 20 records; at most seven days, 50 records and 20 calls an hour; answer JSON bounded to 400 KB). Raw is intersected with the enabled levels (LF1 retires the separate "Raw on request" switches) and exists only for screen pictures (already-covered stored frames as JPEG, 640 px, 150 KB each, also returned as image content) and retained typing words; search never uses retained words unless raw typing was authorized for that request. Policy and ST1 admission are checked after redaction. Every answer is a `.sentToAssistant` ledger item whose id is the `answer_id` and whose payload is the exact tool-result text, with details (kind `journal_answer`, redacted query, range, item count, raw flags, pictures, includes-words, agent, path-free session label, hashed session id); the receipt waits for the bridge's written-result receipt, failed attempts record nothing, and the app shows "Looked at your journal: <range> · View". Rules persist actions, outcomes, last matches and suppression fingerprints; agent proposals are bounded to three a day with confidence 0.4–0.7; evaluable and spend rules need evidence from two days of actual reflection; off, deleted and retired fingerprints suppress re-proposal for 30 days. `zeus_rule_shadow {ruleID, wouldHave, amount?, currency?}` posts "I'd have acted on “…” · OK next time? · Not this" (a purchase is always a durable high-priority question, every time, whatever the amount; spend rules stay shadow); `zeus_rule_acted {ruleID, did, undo?}` posts "Did: … · Undo" for approved rules (spend requires a fresh single-use approval id for that exact text and session); the runtime records reported actions and never executes purchases; Undo delivers an idempotent instruction to the original session; declining retires the rule ("Got it. I won't."). Outcome deltas: explicit OK +0.10, acted and unchanged for 24 h +0.03, held message read +0.02 once a day, Undo −0.30, early Show −0.10, shadow No −0.20, timed skip −0.10, ignored −0.05, toggled off −0.30, on +0.10, user edit raises to at least 0.60 and makes the user the author, stale −0.10 per 30 days without a trigger match; user-authored rules never auto-retire, others retire below 0.20, re-enabled rules start at 0.50. Reflection v2 carries bounded summary and topic samples, outcomes since the previous reflection and suppression fingerprints; never retained words or frame bytes. Storage: when the keychain is locked or unavailable, journal and rules writes queue in memory, the Privacy pane says so, and they land on unlock; tests use an injected fixture key and never the user's keychain.

**Consumption.** `zeus_get_learnings` returns `{learnings: [Learning]}` oldest first, in batches bounded by the link's 4 MiB frame. Disabled learning returns an empty array. Only a successfully written tool result marks everything through its last returned learning ID as read; failed writes and disconnects consume nothing, and announcements never mark read. The MCP notification is exactly `notifications/zeus/learning` with `{id, kind, text}`. No raw events cross either interface.

### LM4 learning-delivery clarification

A digest or moment is a durable `Delivery(kind: learning)`, with its stable learning ID,
exact redacted text and `learning_kind` (digest/moment) metadata. It queues even before
an assistant connects, uses the normal tmux/native delivery envelope and requires an
ack. Proven-dead targets retarget to the replacement assistant as user messages and
reflections do. MCP learning notifications remain hints only: writing one does not
create a Sent ledger receipt or consume the item. An ack or successful
`zeus_get_learnings` tool-result consumption creates the exact-text receipt and marks
the learning read; reflection Sent receipts likewise require ack/consumption, not paste
completion. Out-of-order acks never consume unseen earlier learnings.

Optional `LearningDeliveryPresenting` publishes observable pending learning/reflection
snapshots and `DeliveryHold { deliveryID, kind, since, reason }` after ten continuous
minutes held by a draft, busy managed gate or disconnection (olderSetup is reserved for
a proven setup-specific hold). Hold start/reason persist across relaunch; gate clearance
resumes promptly without waiting out retry backoff. This is not permission to overwrite
native drafts. `requestLearningDeliveryCancellation(deliveryID:)` requests the existing
scoped draft confirmation even for one item; confirmation revalidates the draft and
cancels only that item. Sent journal rows remain evidence, never inferred from pending
items disappearing. The ready/sent thread line retains `n_<learning.id>` and exact detail.

- **LM4 erasure boundary.** Delete Everything and deletion of a learning or reflection's
  evidence discard the affected durable deliveries and cancel in-flight sends.
  Discarded deliveries never create a Sent receipt from a late acknowledgment,
  tool-result receipt, or relaunch replay. Native text already pasted is left alone:
  Zeus neither clears nor submits it after erasure; a later manual submission/ack
  records nothing. The stores expose optional synchronous deletion callbacks so this
  boundary takes effect before asynchronous observation/network callbacks run.


### LF1 assistant-folder record

`LearningFolderWriter` mirrors retained, post-safeguard journal content under the effective assistant folder's `Zeus/`, using atomic writes, files 0600 and directories 0700. The applied managed conversation folder takes precedence over the optional persisted Connect-your-own folder. No folder means no export. `LearningFolderProviding` exposes the effective folder, own-folder choice, existing item file, existing day-folder fallback and write error; `LearningFolderRecording` supplies runtime start/stop, managed-folder identity and redacted learning/reflection snapshots. The app injects the shared writer with its enabled-level closure before runtime start.

History backfills in bounded day/file batches. Destination changes leave the previous folder untouched and re-arm observation. Retention, journal deletion and Undo reconcile the export; Finder-deleted files remain deleted. Delete Everything empties only `Zeus/`; `Notes/` is emptied only with explicit `includeAssistantNotes`. Other assistant files are never removed. Retained digests and moments accumulate even when unsent. Reflections use their redacted delivery body; receipts remain exact consumed content.

`LearnSettings.coverPictures` defaults true and propagates through `ScreenPolicy`. Turning it off skips optional text-region, picture and face coverage; OCR spans classified secret, card, iban or identity are still covered. All capture hard stops and text redaction remain enforced. Previously stored frames are never un-covered.
