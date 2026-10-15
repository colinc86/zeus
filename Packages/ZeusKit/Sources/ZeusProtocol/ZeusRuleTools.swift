import Foundation

/// Learning tools accept proposals only: they cannot enable capture, activate an external act or erase evidence.
public enum ZeusRuleTools {
    /// Phase A rule schemas, shared by bridge and runtime.
    public static let tools: [MCPToolDefinition] = {
        let text: JSONValue = ["type": "string"]
        func object(_ fields: [String: JSONValue], _ required: [String] = []) -> JSONValue {
            ["type": "object", "properties": .object(fields), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
        }
        let minute: JSONValue = ["type": "integer", "minimum": 0, "maximum": 1439]
        let trigger = object(["time": object(["startMinute": minute, "endMinute": minute,
            "weekdays": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7]]], ["startMinute", "endMinute"]),
            "apps": ["type": "array", "items": text], "state": text])
        let rule = object(["sentence": ["type": "string", "minLength": 1, "maxLength": 500], "trigger": trigger,
            "kind": ["type": "string", "enum": ["passive", "acts"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "evidence": ["type": "array", "maxItems": 100, "items": text]], ["sentence"])
        return [
            .init(name: "zeus_get_rules", description: "Read active and shadow rules plus the user's new-rule dial. Use rules for timing, tone and preparation. Shadow is not permission to act. Never echo a numeric confidence to the user.", inputSchema: object([:])),
            .init(name: "zeus_propose_rules", description: "Propose up to 20 rules from reflection. Evidence is journal item IDs supplied in that reflection, never invented IDs. Passive rules become active unless Ask me first; external acts always need their first shadow result. Quiet notices let the user review. Never put raw private data in a rule; say what to do, not whom/which account. Trigger dimensions combine with AND; time uses local minutes after midnight, weekdays 1=Sunday. Empty trigger is assistant guidance and never holds peeks. This tool cannot enable learning or execute an external action.",
                  inputSchema: object(["rules": ["type": "array", "minItems": 1, "maxItems": 20, "items": rule]], ["rules"]))
        ]
    }()
}
