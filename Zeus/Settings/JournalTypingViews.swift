import SwiftUI
import ZeusDesign

struct JournalTypingGroupView: View {
    let group: JournalTypingGroup
    let initiallyExpanded: Bool
    var search = ""
    var deleteRun: @MainActor @Sendable (JournalTypingRun) -> Void = { _ in }
    var deleteGroup: @MainActor @Sendable (JournalTypingGroup) -> Void = { _ in }
    @State private var manuallyExpanded: Bool?
    private var expanded: Bool { !search.isEmpty || (manuallyExpanded ?? initiallyExpanded) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyboardButton {
                manuallyExpanded = !expanded
            } label: {
                HStack(spacing: 8) {
                    Text(expanded ? "\u{25BE}" : "\u{25B8}").settingsCaption()
                    Text(JournalDisplay.appName(group.app) + " · " + group.rangeLabel()).settingsHeading()
                    Spacer()
                    Text("\(group.runs.count) \(group.runs.count == 1 ? "stretch" : "stretches")").settingsCaption()
                }
            }.buttonStyle(.plain).accessibilityLabel(JournalDisplay.appName(group.app) + " · " + group.rangeLabel())
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ForEach(group.runs) { run in JournalTypingRunView(run: run, delete: { deleteRun(run) }) }
            }
        }
        .contextMenu {
            Button("Delete \(JournalDisplay.appName(group.app)) \(group.rangeLabel())") { deleteGroup(group) }
        }
        .accessibilityAction(named: Text("Delete this typing group")) { deleteGroup(group) }
    }
}

struct JournalTypingRunView: View {
    let run: JournalTypingRun
    var delete: @MainActor @Sendable () -> Void = {}
    @State private var hovered = false
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(run.clockLabel).settingsCaption().frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(run.topic.isEmpty ? "Typed in \(JournalDisplay.appName(run.app))" : "→ " + run.topic).settingsBody()
                if let words = run.words, !words.isEmpty {
                    TypingWordsFlow {
                        ForEach(Array(run.segments.enumerated()), id: \.offset) { _, segment in
                            switch segment {
                            case .text(let value):
                                Text(JournalItemView.styled(value, palette: palette)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            case .pasted:
                                Text("‹pasted›").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText)
                                    .padding(.horizontal, 5).padding(.vertical, 2).background(palette.field)
                                    .overlay(PixelRoundedRectangle(steps: 1).strokeBorder(palette.fieldBorder, lineWidth: 1)).accessibilityLabel("pasted")
                            }
                        }
                    }
                } else if !run.missingWordsCaption.isEmpty { Text(run.missingWordsCaption).settingsCaption() }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.trailing, 60).fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if hovered { KeyboardButton("Delete", action: delete).accessibilityLabel("Delete typing stretch") }
            }
            .contentShape(Rectangle()).onHover { hovered = $0 }
            .contextMenu { Button("Delete", action: delete) }
            .accessibilityAction(named: Text("Delete typing stretch"), delete)
    }
}

/// Unlike attachment chips, a stored text segment can wrap to several lines. Measure its full constrained height.
struct TypingWordsFlow: Layout {
    private func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640, sizes = sizes(subviews, width: width)
        let rows = ZeusChipFlow.rows(widths: sizes.map(\.width), maxWidth: width, spacing: 4)
        return .init(width: width, height: rows.enumerated().reduce(0) { height, row in
            height + (row.element.map { sizes[$0].height }.max() ?? 0) + (row.offset > 0 ? 4 : 0)
        })
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews, width: bounds.width)
        var y = bounds.minY
        for row in ZeusChipFlow.rows(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: 4) {
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: .init(x: x, y: y), proposal: .init(sizes[index]))
                x += sizes[index].width + 4
            }
            y += (row.map { sizes[$0].height }.max() ?? 0) + 4
        }
    }
}
