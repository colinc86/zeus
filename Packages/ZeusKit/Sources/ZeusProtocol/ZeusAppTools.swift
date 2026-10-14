import Foundation

/// App controls are deliberately a closed list: none grants the assistant authority
/// over its own session, prompts, permissions, user data or learning preferences.
enum ZeusAppTools {
    static let tools: [MCPToolDefinition] = {
        let string: JSONValue = ["type": "string"], boolean: JSONValue = ["type": "boolean"], number: JSONValue = ["type": "number"]
        let position: JSONValue = ["oneOf": [
            ["type": "string", "enum": ["top-left", "top-right", "bottom-left", "bottom-right", "near-active-window"]],
            object(["screen": ["type": "integer", "minimum": 0], "x": number, "y": number], ["screen", "x", "y"])
        ]]
        return [
            tool("zeus_app_state", "Read Zeus's version, available update, look, display geometry, visibility and interaction state. Read formats before writing character/theme JSON. This contains no other agent session's state.", [:]),
            tool("zeus_create_character", "Create and select a character the user asked you to make. Read zeus_app_state.formats.character first; json is the complete JSON file as text. Validated by the real loader. Undo switches back but keeps the file.", ["name": string, "json": string], ["name", "json"]),
            tool("zeus_set_theme", "Select an installed theme by id, only when asked. The change has a local Undo action.", ["id": string], ["id"]),
            tool("zeus_create_theme", "Create and select a theme the user asked you to make. Read zeus_app_state.formats.theme first; json is the complete JSON file as text. Undo switches back but keeps the file.", ["name": string, "json": string], ["name", "json"]),
            tool("zeus_move", "Move Zeus when asked. Prefer near-active-window; do not move it while the user is typing to Zeus. Coordinates are screen points on the named display; the app clamps placement.", ["position": position], ["position"]),
            tool("zeus_set_size", "Set Zeus's size when asked: small, medium or large. Offers local Undo.", ["size": ["type": "string", "enum": ["small", "medium", "large"]]], ["size"]),
            .init(name: "zeus_hide", description: "Hide Zeus temporarily when asked. Supply exactly one of minutes (integer 1–720) or until: tomorrow. Never hide indefinitely; the user gets Show now.", inputSchema: adding(object([
                "minutes": ["type": "integer", "minimum": 1, "maximum": 720], "until": ["type": "string", "enum": ["tomorrow"]]
            ]), "oneOf", [["required": ["minutes"], "not": ["required": ["until"]]], ["required": ["until"], "not": ["required": ["minutes"]]]])),
            .init(name: "zeus_set_appearance", description: "Change any subset of these look-and-feel settings when asked. Omitted fields stay unchanged. Cannot disable quiet hours while your question is pending; cannot change prompts, permission modes, learning, login or update-check preferences.", inputSchema: adding(object([
                "ghost_mode": boolean, "ghost_opacity": number, "ghost_delay_seconds": number,
                "popup_sound": boolean, "popup_sound_name": string, "font": ["type": "string", "enum": ["pixel", "system"]],
                "panel_width": number, "quiet_hours": boolean, "quiet_start_hour": ["type": "integer", "minimum": 0, "maximum": 23],
                "quiet_end_hour": ["type": "integer", "minimum": 0, "maximum": 23]
            ]), "minProperties", 1)),
            tool("zeus_check_for_updates", "Check for an update without installing. Only a version returned by a successful check in this session may be installed.", [:]),
            tool("zeus_install_update", "Install the exact version this session saw in zeus_check_for_updates. Only when asked, or told to keep Zeus current. Zeus announces the update and waits for in-flight work and blocking prompts, up to 60 seconds. The managed session survives relaunch.", ["version": string], ["version"]),
            tool("zeus_get_learnings", "Read unread daily digests and moments, oldest first (newest last); returned learnings are marked read only after the result is written. Call at the start of a day. Use them for timing and tone, never commentary about the user's habits. Raw activity events are never exposed.", [:])
        ]
    }()
    private static func object(_ properties: [String: JSONValue], _ required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String] = []) -> MCPToolDefinition {
        .init(name: name, description: description, inputSchema: object(properties, required))
    }
    private static func adding(_ schema: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = schema else { return schema }; fields[key] = value; return .object(fields)
    }
}
