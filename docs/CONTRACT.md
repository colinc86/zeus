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
   - The connector follows the **effective delivery method**. For "Connect your own" that is the method selected in Settings: channel (only for a Claude bridge that supports channels; otherwise queued), tmux, OpenCode HTTP, or polling only. A Terminal pane the user picked is honoured even when the same session also offers a channel (CY1, 2026-10-14). For the managed session the runtime picks channel when the managed channel probe has succeeded and tmux otherwise, overriding the Settings value.
3. **Channel format.**
   - `content` is human-readable, e.g. `Reply to "Have you started on the presentation?": No, I haven't.` or `Message from the user: …`.
   - `meta = {kind, delivery_id, card_id?, option_id?}`. Keys must match `[A-Za-z0-9_]`.
   - A skipped question (TB1) is `content = The user skipped "<title>".` (the body stands in when there is no title), `meta.kind = "skipped"`, with `delivery_id` and `card_id` and no `option_id`.
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
width), maximum half the screen, persisted in Settings and clamped on screen change. `ZeusBubble(maxWidth:)` follows it.

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

5. **Right-click on Zeus.** A context menu with: Talk to Zeus, Settings…, Character ▸, Size ▸, Hide for 1 hour, Hide until tomorrow, Quit.
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
   - **Ends when** the session posts a new card (`zeus_say` / `zeus_ask` / `zeus_present`), calls `zeus_set_status` with `auto` or any other state, the override TTL expires, the session disconnects, or the delivery is discarded. It also ends after **5 minutes with no activity** from that session (`.sent` and `.thinking` only; `.working` follows its TTL). Only a newly delivered message or answer, or an explicit `zeus_set_status` with `thinking`/`working`, starts it again. Acks and other tool calls only advance a row that already exists (`.sent` → `.thinking`); they never create one (P12).
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
8. **Requirements.** tmux and the chosen agent CLI must be installed; Settings detects both, with a one-line install hint when missing. The agent must already be logged in; a login screen is just a blocked state (item 5).

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

**Store.** `~/Library/Application Support/Zeus/Activity/<yyyy-mm-dd>.jsonl`, mode 0600. Raw events kept 30 days (Settings: 7–90); digests kept one year. Excluded apps (default: password managers, Keychain Access, Passwords, System Settings; user-editable) are recorded as `private` with a duration and no name.

**What the assistant receives.** Never raw events. A morning digest (about ten lines summarizing the previous day, sent at the first activity of a new day) and at most four "moments" a day from the kinds the user ticked: first activity, back from a break of 2 h+, unusually late start, day winding down. Delivered as an MCP notification plus `zeus_get_learnings` (returns the digests and moments not yet read, newest last). Each send adds a quiet thread line "Sent your daily summary · View" that shows the exact text.

**UI.** Settings › Privacy: the switch (with a one-time sheet listing the scope and the caveat), "What Zeus has recorded" (today's list), Pause for today, Delete everything, the excluded-apps list, retention. Caption: "Summaries go to your assistant, which sends them to its model provider like any message. Raw activity never leaves this Mac."

**Seams.** `LearningsProviding` (the app's `LearningsStore` implements it, the runtime reads it): `unreadLearnings()`, `markLearningsRead(through:)` and the `onNewLearning` callback the runtime turns into the notification. The runtime owns `onNewLearning` while started and releases it at stop. The store owns the quiet "Sent your daily summary · View" thread line.

**Consumption.** `zeus_get_learnings` returns `{learnings: [Learning]}` oldest first, in batches bounded by the link's 4 MiB frame. Disabled learning returns an empty array. Only a successfully written tool result marks everything through its last returned learning ID as read; failed writes and disconnects consume nothing, and announcements never mark read. The MCP notification is exactly `notifications/zeus/learning` with `{id, kind, text}`. No raw events cross either interface.
