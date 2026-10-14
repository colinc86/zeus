import SwiftUI
import ZeusProtocol

/// Every ZeusDesign component in both appearances. Used by the `#Preview` below and by
/// `zeus-sprites gallery` to render `docs/design/components-d2.png`.
public struct ZeusComponentGallery: View {
    /// Static mode for `ImageRenderer`: platform text fields can't be snapshotted, so the field
    /// chrome shows its placeholder as plain text, and the indeterminate bar holds still.
    var snapshot: Bool

    public init(snapshot: Bool = false) {
        self.snapshot = snapshot
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(.dark, font: .pixel)
            column(.light, font: .pixel)
            column(.dark, font: .system)
        }
        .fixedSize()
    }

    private func column(_ scheme: ColorScheme, font: ZeusFontChoice) -> some View {
        let palette = ZeusPalette.for(scheme)
        return VStack(alignment: .leading, spacing: ZeusTheme.Spacing.l) {
            Text("\(scheme == .dark ? "Dark" : "Light") · \(font.displayName)")
                .zeusFont(.caption).foregroundStyle(palette.secondaryText)
            questionCard
            contentCard
            ZeusMenuPicker("Assistant session", choices: [
                ZeusChoice(id: "claude", title: "Claude · Website"),
                ZeusChoice(id: "codex", title: "Codex · Website · pane 3"),
                ZeusChoice(id: "gone", title: "Claude · Notes", detail: "Offline", isEnabled: false),
            ], selection: .constant("codex"), noneTitle: "Auto (newest)")
            HStack(spacing: ZeusTheme.Spacing.m) {
                ZeusBadge(count: 3)
                ZeusBadge(count: 12)
                Button("Primary") {}.buttonStyle(ZeusButtonStyle(.primary))
                Button("Disabled") {}.buttonStyle(ZeusButtonStyle(.secondary)).disabled(true)
            }
        }
        .padding(ZeusTheme.Spacing.xl)
        .frame(width: ZeusTheme.cardMaxWidth + ZeusTheme.Spacing.xl * 2, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(scheme == .dark ? Color(hex: 0x3B4256) : Color(hex: 0xD9DEE8))
        .environment(\.colorScheme, scheme)
        .environment(\.zeusFontChoice, font)
    }

    private var questionCard: some View {
        CardMock(tail: ZeusDialogTail(edge: .bottom, offset: 48)) { palette in
            HStack {
                Text("Presentation").zeusFont(.title).foregroundStyle(palette.title)
                Spacer()
                ZeusPager(index: 0, count: 3, onPrevious: {}, onNext: {})
            }
            ZeusMarkdownText("Your talk on **Q3 planning** is tomorrow at 10. Have you started on it?")
                .zeusFont(.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZeusTheme.Spacing.s) {
                Button("Yes") {}.buttonStyle(ZeusButtonStyle(.primary))
                Button("No") {}.buttonStyle(ZeusButtonStyle(.secondary))
                Button("Skip it") {}.buttonStyle(ZeusButtonStyle(.destructive))
            }
            if snapshot {
                ZeusFieldChrome { Text("Or type a reply…").foregroundStyle(palette.secondaryText) }
            } else {
                ZeusTextField("Or type a reply…", text: .constant(""))
            }
        }
    }

    private var contentCard: some View {
        CardMock(tail: nil) { palette in
            Text("Draft ready").zeusFont(.title).foregroundStyle(palette.title)
            Text("I outlined the deck and started a Keynote draft.").zeusFont(.body)
                .fixedSize(horizontal: false, vertical: true)
            ZeusAttachmentRow(Attachment(id: "a1", kind: .file, label: "Open Keynote draft", target: "~/Documents/Q3 Planning.key"),
                              onOpen: {}, onReveal: {})
            ZeusAttachmentRow(Attachment(id: "a2", kind: .url, label: "Speaker notes", target: "https://docs.example.com/q3"),
                              onOpen: {})
            ZeusProgressBar(value: 0.62)
            ZeusProgressBar(value: snapshot ? 0.0 : nil)
        }
    }
}

/// A sample card body inside the dialog chrome.
private struct CardMock<Content: View>: View {
    let tail: ZeusDialogTail?
    @ViewBuilder let content: (ZeusPalette) -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            content(ZeusPalette.for(scheme))
        }
        .frame(width: ZeusTheme.cardMaxWidth - ZeusTheme.Spacing.m * 2 - ZeusTheme.borderWidth * 2, alignment: .leading)
        .zeusDialog(tail: tail)
    }
}

#Preview("Zeus components") {
    let _ = ZeusFonts.registerBundled()
    ZeusComponentGallery()
}
