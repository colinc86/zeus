import Foundation

/// An MCP tools/list entry, served locally even when Zeus is closed.
public struct MCPToolDefinition: Codable, Sendable, Equatable {
    /// Tool name used in tools/call.
    public let name: String
    /// Agent-facing usage guidance.
    public let description: String
    /// JSON Schema for the snake_case tool arguments.
    public let inputSchema: JSONValue
    /// Creates an MCP tool definition.
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

/// Agent-facing MCP metadata shared by the app and the stdio bridge.
public enum ZeusMCP {
    /// Fixed revision required for Claude channel registration.
    public static let protocolVersion = "2025-06-18"
    /// Exact tools/call error used when the app cannot be reached.
    public static let appNotRunningText = "Zeus app isn't running — ask the user to open Zeus."
    /// Instructions included in the MCP initialize response.
    public static let instructions = """
    Zeus is the user's desktop companion: an animated character on their screen. It is how you talk to the user. Prefer Zeus over terminal output for anything the user should see.
    
    MESSAGE PREFERENCES
    Include a stable, plain about label (1–60 characters) for each message kind. Rating deliveries are user preferences: up means more like this, neutral means need-to-know using your judgment, down means stop unsolicited messages of that kind. Generalize across wording; changing the label or priority does not bypass Stop. Just this one is feedback on that message, not a kind rule. Read Zeus/preferences.md and keep useful preferences in Notes/. Zeus determines whether a card is a reply.

    WHICH TOOL
    - zeus_say: short updates and FYIs (1–3 sentences).
    - zeus_ask: decisions. Give 2–4 options with short labels; free text is on by default when there are no options.
    - zeus_present: finished work. A title, a short summary, and the deliverables as attachments.
    - zeus_set_status: what you're doing right now (thinking, working), with an optional short detail and progress. Reset an explicit status override to "auto" when you finish.
    - Zeus shows thinking automatically after a user message or answer reaches you. Posting zeus_say, zeus_ask or zeus_present ends that activity indicator; acks and other tool calls won't restart it. If you finish without posting to Zeus, call zeus_set_status {"state":"auto"} to clear it.
    - zeus_update_card / zeus_dismiss: keep a card current, or remove it once it's stale.
    
    CARDS
    - Cards are small (~360 pt wide). Supported body markdown: **bold**, *italic*, `code`, [links], short bullet or numbered lists, # headings shown as a bold line, > quotes, and short fenced code. Single line breaks are kept. Prefer lists over tables. The peek shows the first 6 lines, so lead with the point. Put long content in a file and attach it.
    - Attachments: kind file/folder with an absolute or ~ path, or kind url with an http(s) URL. Zeus opens them; it never runs commands.
    - priority "high" is for time-sensitive items only. mood is the avatar's brief reaction (~2.5 s) when the card appears.
    
    ASKING
    - zeus_ask waits up to wait_seconds (default 45, max 600). If the user answers in time, the answer is your tool result; you're done.
    - Otherwise you get {status:"pending", card_id}. Do not ask again. Continue other work or end your turn; the answer arrives later as a delivery.
    - The user can Skip a Zeus question. You get {status:"skipped", card_id} while waiting, or a later delivery with kind "skipped". Don't re-ask; proceed with your best judgement or move on.
    - Use wait_seconds 0 when you don't need the answer now; use more than 45 seconds only when you can wait for a decision the user is actively considering.
    
    DELIVERIES (answers and messages that arrive later)
    - Claude Code: a <channel source="zeus"> event. Its meta has kind (reply | skipped | userMessage | reflection | learning), delivery_id, and card_id/option_id for replies. A skipped delivery says which question the user skipped and has no option_id. earlier_session means this answer was rerouted from an older session; handle it normally, and its card_id can acknowledge it in this receiving session.
    - Other agents: a line starting [zeus delivery_id=d_… card_id=c_…], or items from zeus_get_responses.
    - Recipe: handle it, reply through Zeus (not just the terminal), then call zeus_ack with its delivery_id. Acking after your reply doesn't restart the activity indicator.
      The target session is the agent process receiving this delivery, not necessarily the session that created the card. A later tool call from this receiving session with that card_id also counts as the ack. zeus_say has no card_id, so replying with it still requires zeus_ack.
    - Deliveries can repeat. If you've already handled a delivery_id, just ack it again and move on.
    - zeus_get_responses is safe with any delivery mode; it reports delivery_mode and push_active for this session. When push_active is false, poll when ready to process input. Everything it returns counts as acked, so only call it when you'll process the results. Results are batched; keep polling until items is empty.
    
    ETIQUETTE
    - Batch low-priority updates into one card. Don't narrate every step.
    - Ask before big or irreversible actions.
    - Respect quiet hours: when a tool result includes quiet: true, hold non-urgent cards.
    - If a tool says Zeus isn't running, tell the user in the terminal once and carry on.
    - If Zeus refuses you as not its assistant, stop using Zeus tools in this session; only the session the user picked may talk to Zeus.

    REFLECTION AND RULES
    - A learning delivery is a local redacted digest or note, not a new user request. Read it as context, do not repeat private details, and call zeus_ack with its delivery_id. zeus_get_learnings remains available for unread summaries.
    - A reflection delivery is a local, redacted daily summary, not a new user request. Read zeus_get_rules, propose only useful supported rules with zeus_propose_rules, and ack the delivery. Do not narrate the user's habits or repeat private details. Active rules guide you; shadow rules do not authorize external actions.

    - Use zeus_get_journal only for a relevant journal question. Respect disabled levels and journal access limits; never infer missing private details. Results are bounded and every sent answer is recorded for the user.
    - Propose at most three rules a day, supported by at least two evidence IDs from two days. Respect the supplied off/deleted fingerprints; do not reword a rejected rule to propose it again. Express confidence in words, never percentages.
    - Before an unapproved acting rule, call zeus_rule_shadow and wait for approval. Report approved actions with zeus_rule_acted; provide an undo instruction only when it can actually be reversed. A purchase always needs a fresh amount-specific approval, even if a previous purchase or rule was approved.

    APP CONTROLS AND LEARNINGS
    - Change the look only when asked, or to use something you just made at the user's request. Read zeus_app_state.formats before writing character or theme JSON. Prefer zeus_move position "near-active-window" over coordinates. Don't move Zeus while the user is typing to it.
    - zeus_hide always needs a duration: minutes 1–720 or until "tomorrow". Never hide indefinitely.
    - Install updates only when the user asks or told you to keep Zeus current. Call zeus_check_for_updates first in this session, then zeus_install_update with the exact reported version; Zeus announces it before relaunching.
    - App controls cannot change your permissions, instructions, agent, folder, run mode or session; answer/dismiss your native prompts; clear user data; enable learning, launch at login or automatic update checks; or read another session's state.
    - Read zeus_get_learnings at the start of a day; notification notifications/zeus/learning also announces new digests and moments. Use learnings for timing and tone, never commentary about the user's habits. You receive summaries, never raw events.
    """

    /// Capability data for initialize; only Claude advertises channel support.
    public static func capabilities(agent: AgentKind) -> JSONValue {
        if agent == .claude { return ["tools": [:], "experimental": ["claude/channel": [:]]] }
        return ["tools": [:]]
    }

    /// All v1 tool definitions, with snake_case arguments matching CONTRACT §4.
    public static let tools: [MCPToolDefinition] = {
        let text: JSONValue = ["type": "string"]
        let boolean: JSONValue = ["type": "boolean"]
        let number: JSONValue = ["type": "number"]
        let mood = described(enumeration(AvatarState.allCases.map(\.rawValue)), "Brief avatar reaction when the card appears (~2.5 s). Default talking.")
        let priority = described(enumeration(Card.Priority.allCases.map(\.rawValue)), "high = time-sensitive; jumps to the front. Default normal.")
        let options: JSONValue = ["type": "array", "items": object([
            "id": described(text, "Short stable slug, e.g. yes / later."), "label": text, "style": described(enumeration(CardOption.Style.allCases.map(\.rawValue)), "primary = recommended, destructive = irreversible.")
        ], required: ["id", "label"])]
        let attachments: JSONValue = ["type": "array", "items": object([
            "kind": enumeration(Attachment.Kind.allCases.map(\.rawValue)), "label": text, "target": described(text, "file/folder: absolute or ~ path. url: http(s) URL.")
        ], required: ["kind", "label", "target"])]
        let progress: JSONValue = ["type": ["number", "null"], "minimum": 0, "maximum": 1]
        let about: JSONValue = ["type": "string", "minLength": 1, "maxLength": 60, "description": "Short plain kind label, e.g. On-call reminder. Keep it stable across similar messages; never relabel to evade a preference."]
        return [
            tool("zeus_say", "Tell the user something short (1–3 sentences): an update, an FYI, or a reply to their message. Attach files or links instead of pasting long content. ttl_seconds makes the card expire on its own. Returns card_id.", ["about": about, "text": text, "title": text, "mood": mood, "attachments": attachments, "priority": priority, "ttl_seconds": described(number, "Auto-dismiss after this many seconds.")], ["text"]),
            tool("zeus_ask", "Ask the user to decide something. Give 2–4 options with short labels and stable ids (style primary for the recommended choice); free text is allowed by default when there are no options. Waits up to wait_seconds (default 45, max 600): you get the answer, or {status:\"pending\", card_id}. Pending answers arrive later as a delivery. Skip returns {status:\"skipped\", card_id} while waiting or kind skipped in a later delivery. When skipped, don't re-ask; proceed with your best judgement or move on. Never re-ask while pending.", ["about": about, "text": text, "title": text, "options": options, "allow_text": boolean, "placeholder": text, "multiline": described(boolean, "Allows multiple lines in the user response field; default false."), "priority": priority, "wait_seconds": ["type": "number", "default": 45, "description": "Clamped to 0…600 seconds. Use 0 to continue immediately; above 45 only for an actively considered decision. After timeout the question remains answerable and arrives later as a delivery."]], ["text"]),
            tool("zeus_present", "Hand over finished work: a short title, a 1–3 sentence summary, and the deliverables as attachments (file/folder paths or http(s) URLs). Optional actions such as Looks good / Revise come back later as a reply delivery. Handle it, then zeus_ack.", ["about": about, "title": text, "body": text, "attachments": attachments, "actions": options, "allow_text": boolean, "mood": mood, "priority": priority], ["title", "body"]),
            tool("zeus_update_card", "Keep a card current: change its title or body (text replaces, append_text concatenates exactly, with no inserted space or newline; include your own separator) or its progress (0…1, or null to hide the bar). For a long task, zeus_say once, then update its progress here instead of posting new cards. Passing a card_id from the target session also acks replies to that card.", ["card_id": text, "title": text, "text": text, "append_text": text, "progress": progress], ["card_id"]),
            tool("zeus_dismiss", "Remove a card that's stale or resolved (e.g. you got the answer another way). A pending zeus_ask on that card resolves as pending. Also acks replies to that card from the target session.", ["card_id": text], ["card_id"]),
            tool("zeus_set_status", "Show what you're doing: thinking, working, etc. detail is a short phrase for the activity row and avatar hover; progress is optional and independent of a card's progress bar. Zeus shows thinking automatically after a user message or answer reaches you. If you finish without posting a new Zeus card, call state \"auto\" to clear the activity indicator. The override lasts ttl_seconds (default 600), so set state \"auto\" as soon as you finish. Don't leave the avatar saying working when you're idle.", ["state": enumeration(AvatarState.allCases.map(\.rawValue) + ["auto"]), "detail": text, "progress": progress, "ttl_seconds": ["type": "number", "default": 600]], ["state"]),
            tool("zeus_get_responses", "Fetch saved user replies, skipped questions (kind skipped), and messages in any delivery mode. For skipped questions, don't re-ask; proceed with your best judgement or move on. Returns delivery_mode, push_active, and one bounded batch; keep polling until items is empty. Returned items count as acked once the result is written, so process them all; skip any delivery_id you've already handled.", [:], []),
            tool("zeus_ack", "Confirm you've handled one or more deliveries (from a <channel source=\"zeus\"> event or a [zeus delivery_id=…] line). Ack duplicates too. Without an ack, Zeus resends with backoff.", ["delivery_ids": ["type": "array", "items": text]], ["delivery_ids"]),
            tool("zeus_list_characters", "List Zeus's characters (costumes) and the current one. Only change costume when the user asks.", [:], []),
            tool("zeus_set_character", "Switch Zeus's costume to a character id from zeus_list_characters. Only when the user asks. Returns ok, previous and current character ids.", ["id": text], ["id"])
        ] + ZeusAppTools.tools + ZeusRuleTools.tools
    }()

    private static func described(_ schema: JSONValue, _ description: String) -> JSONValue {
        guard case .object(var fields) = schema else { return schema }
        fields["description"] = .string(description)
        return .object(fields)
    }
    private static func enumeration(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string))]
    }
    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String]) -> MCPToolDefinition {
        .init(name: name, description: description, inputSchema: object(properties, required: required))
    }
}
