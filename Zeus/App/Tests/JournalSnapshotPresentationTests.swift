import AppKit
import Foundation
import SwiftUI
import ZeusDesign
import Observation
import Testing
@testable import Zeus

@MainActor struct JournalSnapshotPresentationTests {
    @Test func filtersDuringLoadUseLatestSelectionAndNeverRescanLoadedData() async {
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [item("today", at: now), item("yesterday", at: now.addingTimeInterval(-86400))]
        let model = JournalViewerModel(journal: source, now: now)
        #expect(model.isLoading && model.items.isEmpty)
        await source.requested()
        model.day = now.addingTimeInterval(-86400); model.level = 2; model.app = "test.editor"; model.search = "yesterday"
        source.finish()
        await model.waitForLoad()
        #expect(!model.isLoading)
        #expect(model.items.map(\.id) == ["yesterday"])
        for value in ["", "y", "yes", "yesterday"] { model.search = value }
        #expect(source.scans == 1)
        #expect(source.synchronousReads == 0)
    }

    @Test func erasedSnapshotCannotPublishAndFailureClearsOldData() async {
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [item("forgotten", at: now)]
        let model = JournalViewerModel(journal: source, now: now)
        await source.requested()
        source.records = []; source.revision += 1
        source.finish()
        await source.requested()
        #expect(model.items.isEmpty)
        source.finish()
        await model.waitForLoad()
        #expect(model.items.isEmpty && !model.isLoading)
        source.records = [item("kept", at: now)]; source.revision += 1
        model.reload(); await source.requested(); source.finish(); await model.waitForLoad()
        #expect(model.items.count == 1)
        model.reload(); await source.requested(); source.fail(); await model.waitForLoad()
        #expect(model.items.isEmpty && model.timeline.isEmpty)
        #expect(model.error != nil && !model.isLoading)
    }

    @Test func answerNavigationWaitsUntilItsRowsExist() async {
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [.init(id: "answer", time: now.addingTimeInterval(-86400), level: .activity, kind: .sentToAssistant,
            payload: .init(.init(description: "Sent a note", text: "Exact received text")))]
        let model = JournalViewerModel(journal: source, now: now)
        model.showAnswer(id: "answer")
        #expect(model.answerSelectionRevision == 0)
        await source.requested(); source.finish(); await model.waitForLoad()
        #expect(model.items.map(\.id) == ["answer"])
        #expect(model.sentOnly && model.selectedAnswerID == "answer" && model.answerSelectionRevision == 1)
    }

    @Test(arguments: [false, true]) func nativeLoadingAndPictureRecoveryCopy(dark: Bool) async throws {
        ZeusFonts.registerBundled()
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [item("Synthetic window", at: now)]
        let model = JournalViewerModel(journal: source, now: now)
        await source.requested()
        let scheme: ColorScheme = dark ? .dark : .light
        let host = TestHostingView(rootView: AnyView(JournalWindowView(model: model)
            .environment(\.accessibilityEnabled, true).environment(\.colorScheme, scheme)
            .background(ZeusPalette.for(scheme).panel)))
        let window = JournalAuditPanel(contentRect: .init(x: -20000, y: -20000, width: 720, height: 520),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Self.layout(host)
        #expect(Self.labels(host).contains("Loading what Zeus kept…"))
        #expect(!Self.labels(host).contains("Nothing kept on this day."))
        try Self.render(host, "loading-" + (dark ? "dark" : "light"))
        model.search = "Synthetic"; source.finish(); await model.waitForLoad()
        try await Self.layout(host)
        #expect(!Self.labels(host).contains("Loading what Zeus kept…"))
        #expect(model.items.count == 1 && source.scans == 1)

        let pictures = PictureRecoveryJournal()
        pictures.records = [.init(id: "unavailable", time: now, level: .screen, kind: .frame,
            payload: .init(.init(description: "Reviewing a synthetic document.")))]
        pictures.unavailable = true
        let viewer = JournalViewerModel(journal: pictures, now: now)
        host.rootView = AnyView(JournalWindowView(model: viewer)
            .environment(\.accessibilityEnabled, true).environment(\.colorScheme, scheme)
            .background(ZeusPalette.for(scheme).panel))
        try await Self.layout(host)
        try Self.render(host, "unavailable-" + (dark ? "dark" : "light"))
        #expect(viewer.pictures.caption(try #require(viewer.pictures.rows.first)) == "Picture can't be shown right now.")
        pictures.unavailable = false; pictures.hasFile = false; viewer.reload()
        try await Self.layout(host)
        try Self.render(host, "missing-" + (dark ? "dark" : "light"))
        #expect(viewer.pictures.error == nil)
        #expect(viewer.pictures.caption(try #require(viewer.pictures.rows.first)) == "Picture missing: Zeus can't find its file.")
    }
    private static func layout(_ host: NSView) async throws {
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private static func labels(_ root: NSObject) -> [String] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> [String] {
            guard depth < 64, seen.count < 2048, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let label: String?, children: [Any]
            if let node = node as? any NSAccessibilityProtocol {
                label = node.accessibilityLabel(); children = node.accessibilityChildren() ?? []
            } else {
                let l = NSSelectorFromString("accessibilityLabel"), c = NSSelectorFromString("accessibilityChildren")
                label = node.responds(to: l) ? node.perform(l)?.takeUnretainedValue() as? String : nil
                children = node.responds(to: c) ? node.perform(c)?.takeUnretainedValue() as? [Any] ?? [] : []
            }
            return [label].compactMap { $0 } + children.compactMap { $0 as? NSObject }.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
    private static func render(_ host: NSView, _ name: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FX24_RENDER"] ?? env["TEST_RUNNER_FX24_RENDER"] else { return }
        let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    private func item(_ id: String, at time: Date) -> JournalItem {
        .init(id: id, time: time, level: .focus, app: "test.editor", kind: .focus, payload: .init(.init(description: id)))
    }
}

@MainActor private final class SnapshotPresentationJournal: JournalSnapshotProviding {
    var revision: UInt64 = 0
    var lastError: String? { nil }
    var records: [JournalItem] = []
    var scans = 0
    var synchronousReads = 0
    private var pending: CheckedContinuation<JournalSnapshot, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var captured: JournalSnapshot?
    func journalSnapshot() async throws -> JournalSnapshot {
        scans += 1
        captured = .init(revision: revision, items: records, expiresAt: nil)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation; waiter?.resume(); waiter = nil
        }
    }
    func requested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        guard let pending, let captured else { return }
        self.pending = nil; self.captured = nil; pending.resume(returning: captured)
    }
    func fail() {
        let pending = pending; self.pending = nil; captured = nil
        pending?.resume(throwing: LearningStorageError.keyUnavailable)
    }
    func items(matching query: JournalQuery) throws -> [JournalItem] { synchronousReads += 1; return records }
    func append(_ item: JournalItem) throws { records.append(item); revision += 1 }
    func delete(_ selection: JournalDeletion) throws { records = []; revision += 1 }
    func export(matching query: JournalQuery) throws -> Data { try JSONEncoder().encode(records) }
    func prune(retention: JournalRetention, now: Date) throws {}
}

@MainActor private final class JournalAuditPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
