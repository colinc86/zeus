import AppKit
import ImageIO
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class FolderFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lf1_" + UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let journal: EncryptedJournalStore
    let writer: LearningFolderWriter
    let first: URL
    let second: URL
    init() throws {
        first = root.appendingPathComponent("first"); second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let now = now
        journal = .init(root: root.appendingPathComponent("journal"), keyProvider: FixtureJournalKey(), calendar: calendar, clock: { now })
        writer = .init(journal: journal, rules: nil, stateURL: root.appendingPathComponent("state.json"),
            enabledLevels: { [.activity, .focus, .screen, .typed] }, redactor: FixtureLearningRedactor(), calendar: calendar)
        writer.setFolder(first); writer.start(learnings: EmptyLearnings())
    }
    func item(_ id: String, text: String = "Safe ‹name›", level: JournalLevel = .focus) -> JournalItem {
        .init(id: id, time: now, level: level, kind: .focus, payload: .init(.init(description: text)))
    }
    func stop() { writer.stop(); try? FileManager.default.removeItem(at: root) }
}

@Suite @MainActor struct LearningFolderTests {
    @Test func layoutPermissionsAndFolderSwitchKeepObserving() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        let first = f.item("one"); try f.journal.append(first); await f.writer.flush()
        let old = try #require(f.writer.fileURL(forJournalItem: first))
        #expect(try String(contentsOf: old, encoding: .utf8).contains("Safe ‹name›"))
        #expect((try FileManager.default.attributesOfItem(atPath: old.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: old.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        f.writer.setFolder(f.second); await f.writer.flush()
        let destination = try #require(f.writer.fileURL(forJournalItem: first))
        #expect(destination.path.hasPrefix(f.second.path)); #expect(FileManager.default.fileExists(atPath: old.path))
        try f.journal.append(f.item("two", text: "AFTER_SWITCH"))
        // No explicit refresh: the generation change must re-arm observation.
        try await eventually { (try? String(contentsOf: destination, encoding: .utf8).contains("AFTER_SWITCH")) == true }
        #expect(try !String(contentsOf: old, encoding: .utf8).contains("AFTER_SWITCH"))
        #expect(f.writer.dayFolderURL(for: f.now) == destination.deletingLastPathComponent())
    }
    @Test func deletionUndoAndFinderDeletionHaveDifferentSemantics() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        let item = f.item("one"); try f.journal.append(item); await f.writer.flush()
        let url = try #require(f.writer.fileURL(forJournalItem: item))
        try f.journal.delete(.item(item.id)); await f.writer.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try f.journal.append(item); await f.writer.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url); await f.writer.flush()
        try f.journal.append(f.item("two")); await f.writer.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let disk = try LearningFolderDisk(stateURL: f.root.appendingPathComponent("state.json"))
        let relative = String(url.path.dropFirst(f.first.path.count + 1))
        try disk.apply([.init(path: relative, data: Data("replacement".utf8), ids: [item.id])], root: f.first, token: disk.invalidate())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(f.writer.lastWriteError == nil)
    }
    @Test func allDeletionPreservesNotesUnlessExplicitAndNeverTouchesTemplates() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        let notes = f.first.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let note = notes.appendingPathComponent("own.md"), template = f.first.appendingPathComponent("AGENTS.md")
        try Data("assistant".utf8).write(to: note); try Data("template".utf8).write(to: template)
        try f.journal.append(f.item("one")); await f.writer.flush()
        try f.journal.delete(.all); await f.writer.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.first.appendingPathComponent("Zeus").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: note.path))
        try f.writer.deleteFolderContents(includeAssistantNotes: true)
        #expect(!FileManager.default.fileExists(atPath: note.path))
        #expect(try String(contentsOf: template, encoding: .utf8) == "template")
    }
    @Test func managedFolderWinsAndDisabledLevelRemovesExport() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        let item = f.item("one"); try f.journal.append(item)
        f.writer.setManagedFolder(f.second); await f.writer.flush()
        let file = try #require(f.writer.fileURL(forJournalItem: item))
        #expect(file.path.hasPrefix(f.second.path))
        f.writer.enabledLevels = { [.activity] }; await f.writer.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        f.writer.enabledLevels = { [.focus] }; await f.writer.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        f.writer.setManagedFolder(nil); await f.writer.flush(); #expect(f.writer.folderURL == f.first.standardizedFileURL.resolvingSymlinksInPath())
    }
    @Test func retentionAndAppDeletionRemoveTheirFilesAndUndoRestores() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        let old = JournalItem(id: "old", time: f.now.addingTimeInterval(-86400 * 100), level: .focus, app: "owned.fixture", kind: .focus,
            payload: .init(.init(description: "Old synthetic record")))
        try f.journal.append(old); await f.writer.flush()
        let path = try #require(f.writer.fileURL(forJournalItem: old))
        try f.journal.prune(retention: .init(), now: f.now); await f.writer.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try f.journal.append(old); await f.writer.flush()
        #expect(FileManager.default.fileExists(atPath: path.path))
        try f.journal.delete(.app("owned.fixture")); await f.writer.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try f.journal.append(old); await f.writer.flush()
        try f.journal.delete(.day(old.time)); await f.writer.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func exportRefusesLinksOutsideOwnedZone() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        f.writer.stop()
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let zone = f.first.appendingPathComponent("Zeus")
        try? FileManager.default.removeItem(at: zone)
        try FileManager.default.createSymbolicLink(at: zone, withDestinationURL: outside)
        f.writer.start(learnings: EmptyLearnings()); try f.journal.append(f.item("one")); await f.writer.flush()
        #expect(f.writer.lastWriteError != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func pictureOptOutStillCoversCardPixelsAndDropsPasswordDialogs() async throws {
        let image = NSImage(size: NSSize(width: 1000, height: 300), flipped: true) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
            for (index, line) in ["Card 4111 1111 1111 1111", "Contact synthetic@example.com"].enumerated() {
                (line as NSString).draw(at: NSPoint(x: 30, y: 50 + index * 70), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.black])
            }
            return true
        }
        var rect = NSRect(x: 0, y: 0, width: 1000, height: 300)
        let pixels = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let raster = try #require(CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.draw(pixels, in: CGRect(x: 0, y: 0, width: 1000, height: 300))
        let captured = CapturedScreenFrame(image: try #require(raster.makeImage()))
        let processor = FrameRedactor(redactor: LocalRedactor(useOnDeviceModel: false))
        let context = ScreenContext(bundleID: "owned.fixture", appName: "Fixture", windowTitle: "Synthetic", windowID: 1, processID: 1)
        let safe = try await processor.redact(captured, context: context, coverPictures: false)
        #expect(safe.frame.value.boxes.contains { $0.kind == .text })
        #expect(!safe.frame.value.boxes.contains { $0.kind == .face || $0.kind == .picture })
        let output = try #require(CGImageSourceCreateWithData(safe.frame.value.heic as CFData, nil))
        let outputPixels = CapturedScreenFrame(image: try #require(CGImageSourceCreateImageAtIndex(output, 0, nil)))
        let text = try await Task.detached { try FrameRedactor.textLines(outputPixels.image).map(\.0).joined(separator: " ") }.value
        #expect(!text.contains("4111")); #expect(text.contains("synthetic@example.com"))
        var dialog = context; dialog.windowTitle = "Enter your password"
        do { _ = try await processor.redact(captured, context: dialog, coverPictures: false); Issue.record("Password dialog must be dropped") }
        catch ScreenCaptureError.sensitive { }
    }
    @Test func reflectionFileAndReceiptContainExactDeliveredPaths() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true); defer { f.stop() }
        for index in 0..<10 {
            try f.journal.append(.init(id: "evidence-\(index)", time: f.clock.now.addingTimeInterval(Double(index - 10)),
                level: .focus, kind: .focus, payload: .init(.init(description: "Synthetic project step \(index)"))))
        }
        f.box.enabled = true; f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange()
        try await eventually { !f.connector.deliveries.isEmpty }
        let sent = try #require(f.connector.deliveries.first)
        #expect(sent.content.contains("\n\nFiles: Zeus/reflections/"))
        let relative = try #require(sent.content.components(separatedBy: "Files: ").last)
        let root = try #require(f.folder?.folderURL)
        #expect(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == sent.content)
        _ = try f.runtime.acknowledge(ids: [sent.id], sessionKey: sent.sessionKey)
        let receipt = try #require(f.journal.items(matching: .init()).first { $0.kind == .sentToAssistant })
        #expect(receipt.payload.value.text == sent.content)
    }
    @Test func retainedFrameAndTypingWordsExportAndExpireTogether() async throws {
        let f = try FolderFixture(); defer { f.stop() }
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let bytes = try FrameRedactor.heic(#require(context.makeImage()))
        let frame = JournalItem(id: "covered", time: f.now, level: .screen, app: "owned.fixture", kind: .frame,
            payload: .init(.init(description: "Covered fixture")))
        try f.journal.appendFrame(.init(.init(heic: bytes, width: 20, height: 20, boxes: [], appName: "Fixture", windowTitle: "Safe")), item: frame)
        let description = JournalItem(id: "description", time: f.now, level: .screen, app: "owned.fixture", kind: .description,
            payload: .init(.init(description: "Safe description", details: ["frame_id": frame.id])))
        try f.journal.append(description)
        let words = JournalItem(id: "words", time: f.now, level: .typed, kind: .typedText,
            payload: .init(.init(description: "Topic", text: "Redacted retained words", topic: "Working on fixtures")))
        try f.journal.append(words); await f.writer.flush()
        let jpeg = try #require(f.writer.fileURL(forJournalItem: frame)), markdown = try #require(f.writer.fileURL(forJournalItem: description))
        #expect(jpeg.pathExtension == "jpg" && markdown.pathExtension == "md")
        #expect(jpeg.deletingPathExtension() == markdown.deletingPathExtension())
        #expect(try Data(contentsOf: jpeg).starts(with: [0xff, 0xd8]))
        let typing = try #require(f.writer.fileURL(forJournalItem: words))
        #expect(try String(contentsOf: typing, encoding: .utf8).contains("Redacted retained words"))
        try f.journal.pruneTyping(words: .none, topicsDays: 30, now: f.now); await f.writer.flush()
        let retained = try String(contentsOf: typing, encoding: .utf8)
        #expect(retained.contains("Working on fixtures") && !retained.contains("Redacted retained words"))
    }
    @Test func mandatoryCoverageNeverDependsOnPicturePreference() {
        #expect(FrameRedactor.mandatoryCover(original: "token", redacted: "‹secret›"))
        #expect(FrameRedactor.mandatoryCover(original: "card", redacted: "‹card›"))
        #expect(FrameRedactor.mandatoryCover(original: "account", redacted: "‹iban›"))
        #expect(FrameRedactor.mandatoryCover(original: "identity", redacted: "‹identity›"))
        #expect(!FrameRedactor.mandatoryCover(original: "person", redacted: "‹name›"))
    }
}
