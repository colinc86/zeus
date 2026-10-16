import Testing
import ZeusProtocol

struct RuleToolSchemaTests {
    @Test(arguments: [0, 540, 1439, -1, 1440])
    func advertisedTimeBoundsAcceptExactlyMinutesInADay(value: Int) throws {
        let tool = try #require(ZeusMCP.tools.first { $0.name == "zeus_propose_rules" })
        let time = try #require(tool.inputSchema["properties"]?["rules"]?["items"]?["properties"]?["trigger"]?["properties"]?["time"]?["properties"])
        for field in ["startMinute", "endMinute"] {
            let schema = try #require(time[field])
            #expect(schema["type"] == .string("integer"))
            let minimum = try #require(number(schema["minimum"]))
            let maximum = try #require(number(schema["maximum"]))
            let accepted = Double(value) >= minimum && Double(value) <= maximum
            #expect(accepted == (value >= 0 && value <= 1439))
        }
    }

    @Test func everyAdvertisedIntegerSchemaHasIntegralBounds() {
        for tool in ZeusMCP.tools { inspect(tool.inputSchema, path: tool.name) }
    }

    private func inspect(_ value: JSONValue, path: String) {
        switch value {
        case .object(let fields):
            if fields["type"] == .string("integer") {
                for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
                    if let bound = fields[key] {
                        guard let value = number(bound) else {
                            Issue.record("Non-numeric integer bound at \(path).\(key)"); continue
                        }
                        #expect(value.isFinite && value.rounded() == value, "Fractional integer bound at \(path).\(key)")
                    }
                }
            }
            for (key, child) in fields { inspect(child, path: path + "." + key) }
        case .array(let values):
            for (index, child) in values.enumerated() { inspect(child, path: path + "[\(index)]") }
        default: break
        }
    }

    private func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value else { return nil }
        return number
    }
}
