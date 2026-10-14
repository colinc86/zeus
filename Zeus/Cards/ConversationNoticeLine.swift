import SwiftUI
import ZeusDesign

/// A quiet thread line (`ThreadNotice`): one caption on the agent side, no bubble, with one plain action.
/// "View" opens the exact text inline; an in-memory action (AC2's Undo) runs once and shows its done title.
/// Never badges, peeks, types out or plays a sound.
struct ConversationNoticeLine: View {
    let notice: ThreadNotice
    let maxWidth: CGFloat
    /// The store still holds this line's in-memory action.
    let hasAction: Bool
    let perform: () -> Void
    @State private var showsDetail = false
    @FocusState private var actionFocused: Bool
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            HStack(spacing: ZeusTheme.Spacing.s) {
                Text(notice.summary).foregroundStyle(palette.secondaryText)
                switch trailing {
                case .button(let title):
                    Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                    Button { act() } label: {
                        Text(title).foregroundStyle(palette.title)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(actionFocused ? palette.focusRing : .clear).frame(height: ZeusTheme.pixel).offset(y: ZeusTheme.pixel)
                            }
                            .frame(minHeight: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable().focused($actionFocused)
                    .accessibilityLabel(title)
                case .done(let title):
                    Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                    Text(title).foregroundStyle(palette.secondaryText)
                case nil:
                    EmptyView()
                }
            }
            .zeusFont(.caption)
            .frame(minHeight: 22)
            if showsDetail, let detail = notice.detail {
                Text(detail).zeusFont(.caption).foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(ZeusTheme.Spacing.s)
                    .background(palette.field)
                    .overlay(Rectangle().strokeBorder(palette.fieldBorder, lineWidth: ZeusTheme.pixel))
                    .accessibilityLabel("Sent text: \(detail)")
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.summary)
    }

    private enum Trailing { case button(String), done(String) }
    /// "View"/"Hide" for a line with text to show; the action while the store holds it; then the done title.
    private var trailing: Trailing? {
        if notice.detail != nil, let title = notice.actionTitle { return .button(showsDetail ? "Hide" : title) }
        if hasAction, let title = notice.actionTitle { return .button(title) }
        return notice.resolvedTitle.map(Trailing.done)
    }
    private func act() {
        if notice.detail != nil { showsDetail.toggle() } else { perform() }
    }
}
