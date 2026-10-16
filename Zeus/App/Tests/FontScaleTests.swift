import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

private struct FontScaleFixture: View {
    @State var draft = "One line\nAnother line"
    @FocusState private var focus: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation").zeusFont(.title)
            ZeusBubble(.agent) {
                ZeusBubbleHeader(title: "Release review", trailing: "14:02")
                ZeusMarkdownText("The **smaller rollout** keeps recovery simple.")
                AttachmentChip(attachment: Attachment(kind: .url, label: "Release plan", target: "https://example.com/plan", summary: "The plan compares the two options and recommends a smaller rollout."), previewInteraction: .rest)
                ZeusFlowLayout(spacing: 8) {
                    ForEach(["More like this", "Neutral", "Stop these"], id: \.self) { title in
                        Button(title) {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    }
                }
            }
            HStack { Text("Sent a daily reflection"); Button("View") {}.buttonStyle(.plain) }.zeusFont(.caption)
            ZeusTypingIndicator(.working, agentName: "Claude", detail: "Reviewing the plan", progress: 0.5)
            ZeusStatusStrip(.idle())
            ZeusComposer(text: $draft, placeholder: "Message your assistant…", focus: $focus, onClearReply: {}, onSend: {})
        }.padding(16)
    }
}

@MainActor @Suite(.serialized) struct FontScaleTests {
    @Test func largerPeekFitsAShortDisplayAndScaleChangesItsMetrics() {
        ZeusFonts.registerBundled()
        let card = Card(kind: .message, title: "Release review", body: String(repeating: "Review the smaller rollout. ", count: 12), attachments: [Attachment(kind: .url, label: "Plan", target: "https://example.com", summary: "A comparison of the two release plans.")])
        for font in ZeusFontChoice.allCases {
            let normal = PeekLayout.measure(card: card, font: font, moreCount: 1, error: nil, answeredOptionID: nil, available: .init(width: 300, height: 400))
            let large = PeekLayout.measure(card: card, font: font, scale: .larger, moreCount: 1, error: nil, answeredOptionID: nil, available: .init(width: 300, height: 400))
            #expect(large.showsMore)
            #expect(large != normal)
            let host = TestHostingView(rootView: PeekContent(card: card, layout: large, moreCount: 1, error: nil, answeredOptionID: nil, tail: nil, reveal: .full).environment(\.zeusFontChoice, font).environment(\.zeusFontScale, .larger))
            #expect(host.fittingSize.height <= 400)
            #expect(host.fittingSize.width <= 300)
            #expect(abs(host.fittingSize.height - large.contentSize.height) <= 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_FS1_RENDER"] == "1" || ProcessInfo.processInfo.environment["FS1_RENDER"] == "1"))
    func renderSizeMatrix() async throws {
        ZeusFonts.registerBundled()
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<4 { root.deleteLastPathComponent() }
        let output = root.appendingPathComponent("build/fs1-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for font in ZeusFontChoice.allCases {
                for scale in ZeusFontScale.allCases {
                    let name = "fs1-\(scale.rawValue)-classic-\(scheme == .light ? "light" : "dark")-\(font.rawValue)"
                    try await render(FontScaleFixture().frame(width: 380), name: name + "-thread", output: output, scheme: scheme, font: font, scale: scale)
                    let card = Card(kind: .message, title: "Release review", body: "The smaller rollout keeps recovery simple. Review the trade-offs before approving the launch.", attachments: [Attachment(kind: .url, label: "Release plan", target: "https://example.com/plan", summary: "The plan compares the two release options.")])
                    let layout = PeekLayout.measure(card: card, font: font, scale: scale, moreCount: 1, error: nil, answeredOptionID: nil, available: .init(width: 320, height: 500))
                    try await render(PeekContent(card: card, layout: layout, moreCount: 1, error: nil, answeredOptionID: nil, tail: nil, reveal: .full).padding(12), name: name + "-peek", output: output, scheme: scheme, font: font, scale: scale)
                    if scale == .larger && font == .pixel {
                        let short = PeekLayout.measure(card: card, font: font, scale: scale, moreCount: 1, error: nil, answeredOptionID: nil, available: .init(width: 320, height: 216))
                        #expect(short.contentSize.height + ZeusDialogTail.height <= 216)
                        try await render(PeekContent(card: card, layout: short, moreCount: 1, error: nil, answeredOptionID: nil, tail: nil, reveal: .full).padding(12), name: name + "-short-240", output: output, scheme: scheme, font: font, scale: scale)
                    }
                }
            }
        }
    }
    private func render<V: View>(_ view: V, name: String, output: URL, scheme: ColorScheme, font: ZeusFontChoice, scale: ZeusFontScale) async throws {
        let host = TestHostingView(rootView: view.environment(\.colorScheme, scheme).environment(\.zeusFontChoice, font)
            .environment(\.zeusFontScale, scale).background(ZeusPalette.for(scheme).panel))
        let size = host.fittingSize
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

}
