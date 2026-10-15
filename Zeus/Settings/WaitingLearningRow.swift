import SwiftUI
import ZeusDesign

/// Pending text is shown separately from receipts, never inserted into the received journal.
struct WaitingLearningRow: View {
    let item: PendingLearningDelivery
    let hold: DeliveryHold?
    let now: Date
    var openTerminal: @MainActor () -> Void = {}
    var restart: @MainActor () -> Void = {}
    var canStart = false
    var start: @MainActor () -> Void = {}
    @State private var expanded = false
    @Environment(\.zeusPalette) private var palette
    var title: String { item.kind == .reflection ? "Day reflection" : item.learningKind == .moment ? "Note" : "Morning summary" }
    var size: String { let words = item.text.split(whereSeparator: \.isWhitespace).count; return "\(words) \(words == 1 ? "word" : "words")" }
    var waitingLabel: String {
        let since = hold?.since ?? item.preparedAt
        let time = Calendar.current.isDate(since, inSameDayAs: now) ? since.formatted(date: .omitted, time: .shortened)
            : since.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Waiting since \(time)" + (hold.map { " · " + Self.reason($0.reason) } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KeyboardButton(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Text(expanded ? "▾" : "▸").settingsCaption()
                    Text(title).settingsBody()
                    Text(size).settingsCaption()
                }
            }.buttonStyle(.plain)
                .accessibilityLabel("\(title), \(size), \(waitingLabel). View exact text")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            Text(waitingLabel).settingsCaption()
            if hold?.reason == .draft {
                KeyboardButton("Open in Terminal", action: openTerminal).accessibilityLabel("Open waiting delivery in Terminal")
            } else if hold?.reason == .olderSetup {
                KeyboardButton("Restart Assistant", action: restart).accessibilityLabel("Restart assistant for waiting delivery")
            }
            else if hold?.reason == .disconnected && canStart {
                KeyboardButton("Start Assistant", action: start).accessibilityLabel("Start Assistant")
            }
            if expanded {
                ZeusFieldChrome { Text(item.text).settingsBody().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityLabel("Prepared text, not yet received: \(item.text)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static func reason(_ reason: DeliveryHold.Reason) -> String {
        switch reason {
        case .draft: "unsent text in its Terminal"
        case .busy: "it's busy"
        case .disconnected: "your assistant isn't connected"
        case .olderSetup: "it was started with an older setup"
        }
    }

}
