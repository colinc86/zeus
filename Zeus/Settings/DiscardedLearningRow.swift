import SwiftUI
import ZeusDesign

/// Exact retained request text, clearly separated from both waiting work and received items.
struct DiscardedLearningRow: View {
    let item: DiscardedLearningDelivery
    @State private var expanded = false
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KeyboardButton(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    ZeusGlyph(.right).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                    Text(item.deliveryKindName).settingsBody()
                    let words = item.text.split(whereSeparator: \.isWhitespace).count
                    Text("\(words) \(words == 1 ? "word" : "words")").settingsCaption()
                }
            }.buttonStyle(.plain)
                .accessibilityLabel("\(item.deliveryKindName), not sent. \(item.queueReason) View exact text")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            Text(item.queueReason).settingsCaption()
            if expanded {
                ZeusFieldChrome { Text(item.text).settingsBody().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityLabel("Not sent: \(item.text)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
