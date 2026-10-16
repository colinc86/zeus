import Foundation

/// Learning tools accept proposals only: they cannot enable capture, activate an external act or erase evidence.
public enum ZeusRuleTools {
    /// Learning rule and journal schemas, shared by bridge and runtime.
    public static let tools: [MCPToolDefinition] = {
        let text: JSONValue = ["type": "string"]
        func object(_ fields: [String: JSONValue], _ required: [String] = []) -> JSONValue {
            ["type": "object", "properties": .object(fields), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
        }
        let minute: JSONValue = ["type": "integer", "minimum": 0.4, "maximum": 0.7439]
        let trigger = object(["time": object(["startMinute": minute, "endMinute": minute,
            "weekdays": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7]]], ["startMinute", "endMinute"]),
            "apps": ["type": "array", "items": text], "state": text, "kind": ["type": "string", "enum": ["spend"]]])
        let rule = object(["sentence": ["type": "string", "minLength": 1, "maxLength": 500], "trigger": trigger,
            "kind": ["type": "string", "enum": ["passive", "acts"]],
            "confidence": ["type": "number", "minimum": 0.4, "maximum": 0.7],
            "evidence": ["type": "array", "maxItems": 100, "items": text]], ["sentence"])
        return [
            .init(name: "zeus_get_journal", description: "Answer the user's request from their permitted journal, never browse out of curiosity. One range up to 7 days, at most 20 calls/hour. Defaults: last day, all enabled levels, 20 items. Summaries/topics only; raw=true returns covered pictures or redacted words only while that level is enabled. Every answer is visible and logged. Never infer removed details or forward journal material to other people.", inputSchema: object([
                "query": text, "from": text, "to": text, "kinds": ["type": "array", "items": ["type": "string", "enum": ["activity", "focus", "screen", "typing"]]],
                "raw": ["type": "boolean"], "limit": ["type": "integer", "minimum": 1, "maximum": 50]])),
            .init(name: "zeus_rule_shadow", description: "Report what you would have done under a shadow rule; DO NOT act. wouldHave starts with a past participle (sent …, bought …) and contains nothing private. Only one shadow notice per rule until answered. Purchases always need amount/currency and a fresh confirmation; standing approval never authorizes payment.", inputSchema: object([
                "ruleID": text, "wouldHave": text, "amount": ["type": "number", "exclusiveMinimum": 0], "currency": text], ["ruleID", "wouldHave"])),
            .init(name: "zeus_rule_acted", description: "Report what you did under an approved active rule after its trigger matched. did is a short nonprivate description; undo is an optional instruction Zeus sends back to this session if the user presses Undo. Without undo the notice offers Not again. For spending, supply the approvalID from zeus_rule_shadow; it must have a fresh affirmative answer for this exact action and amount. Never act from a reflection itself.", inputSchema: object([
                "ruleID": text, "did": text, "undo": text, "approvalID": text], ["ruleID", "did"])),
            .init(name: "zeus_get_rules", description: "Read active and shadow rules plus the user's new-rule dial. Use rules for timing, tone and preparation. Shadow is not permission to act. Never echo a numeric confidence to the user.", inputSchema: object([:])),
            .init(name: "zeus_propose_rules", description: "Propose up to three rules per day, only from a reflection delivered to this session. Evaluable rules need two evidence IDs from two different days. Never re-propose a suppressed fingerprint for 30 days. Spending always requires a fresh amount-bearing user question, every time. Evidence is journal item IDs supplied in that reflection, never invented IDs. Passive rules become active unless Ask me first; external acts always need their first shadow result. Quiet notices let the user review. Never put raw private data in a rule; say what to do, not whom/which account. Trigger dimensions combine with AND; time uses local minutes after midnight, weekdays 1=Sunday. Empty trigger is assistant guidance and never holds peeks. This tool cannot enable learning or execute an external action.",
                  inputSchema: object(["rules": ["type": "array", "minItems": 1, "maxItems": 3, "items": rule]], ["rules"]))
        ]
    }()
}
