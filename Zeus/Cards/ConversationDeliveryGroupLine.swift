import SwiftUI
import ZeusDesign

/// One finished day's delivery lines as a single quiet line (PRIVACY.md §6.1, FX19): "Zeus sent your assistant 3 things · Show".
/// Show lays the day's lines out in place, each with its own View (inline text or the reader for long text); Hide folds them again.
/// Expansion is presentation only; nothing is marked, sent or persisted.
struct ConversationDeliveryGroupLine: View {
    let group: ConversationDeliveryGroup
    let maxWidth: CGFloat
    var announce: @MainActor (String) -> Void = AccessibilityFeedback.announce
    @State private var expanded = false

    static let showTitle = "Show"
    static let hideTitle = "Hide"

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            ConversationNoticeLine(notice: header, maxWidth: maxWidth, hasAction: true, perform: toggle)
            if expanded {
                VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
                    ForEach(group.lines) { line in
                        ConversationNoticeLine(notice: line, maxWidth: maxWidth, hasAction: false, perform: {})
                    }
                }
                .padding(.leading, ZeusTheme.Spacing.m)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(group.lines.count) lines from this day")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: ThreadNotice {
        ThreadNotice(id: group.id, kind: .learning, createdAt: group.lines.first?.createdAt ?? group.day, summary: group.summary,
                     actionTitle: expanded ? Self.hideTitle : Self.showTitle)
    }
    private func toggle() {
        expanded.toggle()
        announce(expanded ? "\(group.summary). Expanded." : "\(group.summary). Collapsed.")
    }
}
