import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

private struct JumpRenderFixture: View {
    let store: CardStore
    let entries: [ConversationEntry]
    let visibility: ConversationVisibility
    let panel: ConversationPanelState
    let questions: [String]
    let height: CGFloat
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZeusBubble(.agent) {
                        ZeusBubbleHeader(title: "Release review", trailing: "14:02")
                        Text("The smaller rollout keeps recovery simple. Review the trade-offs before approving the launch.").zeusFont(.body)
                    }
                    ZeusBubble(.agent) {
                        Text("The earlier notes explain the recovery steps. You can jump back to them or continue to the latest reply.").zeusFont(.body)
                    }
                }
            }.frame(height: height)
                .overlay(alignment: .top) { overlay(.top) }
                .overlay(alignment: .bottom) { overlay(.bottom) }
            ZeusStatusStrip(.idle())
            ZeusComposer(text: $draft, placeholder: "Message your assistant…", focus: $focused, onClearReply: {}, onSend: {})
        }.zeusDialog()
    }
    private func overlay(_ edge: ZeusJumpPillCluster.Edge) -> some View {
        ConversationJumpOverlay(edge: edge, visibility: visibility, entries: entries, store: store,
            questions: questions, lastQuestion: nil, atBottom: false, pending: false, panel: panel,
            unread: { _ in }, latest: {}, question: {})
    }
}

@MainActor @Suite(.serialized) struct ConversationJumpRenderTests {
    @Test func nativeOverlaySeparatesMarkReadFromJump() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jb1-ax-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let cards = (0..<4).map { Card(id: "c\($0)", kind: .question, body: "Question \($0)") }
        cards.forEach { store.add($0) }
        let entries = cards.map { ConversationEntry(id: "card:\($0.id)", timestamp: $0.createdAt, content: .agentCard($0)) }
        let visibility = ConversationVisibility(); visibility.navigationIDs = ["card:c2"]; visibility.jumpsReady = true
        let panel = ConversationPanelState(); panel.isVisible = true
        var jumps: [String] = []
        let host = TestHostingView(rootView: ConversationJumpOverlay(edge: .top, visibility: visibility, entries: entries, store: store,
            questions: ["c0", "c3"], lastQuestion: nil, atBottom: false, pending: false, panel: panel,
            unread: { jumps.append($0) }, latest: { jumps.append("latest") }, question: { jumps.append("question") })
            .frame(width: 380, height: 80).environment(\.accessibilityEnabled, true).environment(\.zeusAnimationsActive, false))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: 380, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func button(_ id: String) throws -> NSObject {
            try #require(jumpAXNodes(host).first { node in
                guard node.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return false }
                return node.perform(NSSelectorFromString("accessibilityIdentifier"))?.takeUnretainedValue() as? String == id
            })
        }
        let unread = try button("jump-unread")
        #expect(unread.perform(NSSelectorFromString("accessibilityLabel"))?.takeUnretainedValue() as? String == ZeusJumpPill.accessibilityLabel(.unread(2)))
        #expect((try button("jump-mark-read") as AnyObject).accessibilityPerformPress?() == true)
        #expect(jumps.isEmpty && store.seenIDs == ["c0", "c1"])
        #expect(CardStore(fileURL: root.appendingPathComponent("cards.json")).seenIDs == store.seenIDs)
        #expect((try button("jump-question") as AnyObject).accessibilityPerformPress?() == true)
        #expect(jumps == ["question"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_JB1_RENDER"] == "1" || ProcessInfo.processInfo.environment["JB1_RENDER"] == "1"))
    func renderPills() async throws {
        ZeusFonts.registerBundled()
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<4 { root.deleteLastPathComponent() }
        let output = root.appendingPathComponent("build/jb1-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("jb1-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixture) }
        for state in ["unread", "latest", "new", "question-above", "question-below", "narrow", "short"] {
            let store = CardStore(fileURL: fixture.appendingPathComponent(state + ".json"))
            let cards = (0..<6).map { Card(id: "c\($0)", kind: .message, body: "Message \($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
            cards.forEach { store.add($0) }
            let above = ["unread", "question-above", "narrow", "short"].contains(state)
            let below = ["new", "question-below", "short"].contains(state)
            store.markSeen(ids: Set(cards.map(\.id)).subtracting((above ? Set(["c0", "c1", "c2"]) : []).union(below ? ["c4", "c5"] : [])))
            let visibility = ConversationVisibility()
            visibility.navigationIDs = ["card:c3"]; visibility.jumpsReady = true
            visibility.awayFromLatest = state == "latest"
            let panel = ConversationPanelState(); panel.isVisible = true
            let questions = ["question-above", "narrow", "short"].contains(state) ? ["c0", "c1"] : state == "question-below" ? ["c4", "c5"] : []
            for scheme in [ColorScheme.light, .dark] {
                for font in ZeusFontChoice.allCases {
                    for scale in [ZeusFontScale.default, .larger] {
                        let view = JumpRenderFixture(store: store, entries: cards.map { .init(id: "card:\($0.id)", timestamp: $0.createdAt, content: .agentCard($0)) },
                            visibility: visibility, panel: panel, questions: questions, height: state == "short" ? 160 : 300)
                            .frame(width: state == "narrow" ? 292 : 412)
                            .environment(\.colorScheme, scheme).environment(\.zeusFontChoice, font).environment(\.zeusFontScale, scale)
                            .environment(\.zeusAnimationsActive, false).background(ZeusPalette.for(scheme).panel)
                        let host = TestHostingView(rootView: view)
                        let size = host.fittingSize
                        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
                        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let name = "jb1-\(state)-classic-\(scheme == .light ? "light" : "dark")-\(font.rawValue)-\(scale.rawValue).png"
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
                        window.contentView = nil; window.close()
                    }
                }
            }
        }
    }
}

/// Walk the accessibility tree, not SwiftUI's private NSView implementation tree.
/// Ignored backing views can forward labels back into their own SwiftUI attachment.
@MainActor func jumpAXNodes(_ root: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any, depth: Int) -> [NSObject] {
        guard depth < 64, visited.count < 2048, let node = value as? NSObject,
              visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        let children: [Any]
        if let accessible = node as? NSAccessibilityProtocol {
            children = accessible.accessibilityChildren() ?? []
        } else {
            let selector = NSSelectorFromString("accessibilityChildren")
            children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        }
        return [node] + children.flatMap { walk($0, depth: depth + 1) }
    }
    return walk(root, depth: 0)
}
