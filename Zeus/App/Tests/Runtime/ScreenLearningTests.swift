import AppKit
import Foundation
import ImageIO
import Testing
@testable import Zeus

@MainActor enum ScreenTestImages {
    static func draw(scroll: CGFloat = 0, bank: Bool = false) throws -> CGImage {
        let size = NSSize(width: 1000, height: 600)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            let lines = bank ? ["Fixture Bank", "Account 4401 2233 9876", "Balance $12,480.17", "Contact example.person@example.com", "Routing 123456789", "Card ending 4242"] :
                (0..<16).map { "Synthetic source line \($0): building a safe fixture" }
            for (index, text) in lines.enumerated() {
                (text as NSString).draw(at: NSPoint(x: 35, y: 50 + CGFloat(index) * 30 - scroll),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), .foregroundColor: NSColor.black])
            }
            return true
        }
        var rect = NSRect(origin: .zero, size: size)
        let native = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let raster = try #require(CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.draw(native, in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        return try #require(raster.makeImage())
    }
}
private struct ScreenNoModel: FrameDescriptionGenerating {
    func generate(app: String, document: String, text: String) async -> FrameDescription? { nil }
}
private struct ScreenFixedModel: FrameDescriptionGenerating {
    func generate(app: String, document: String, text: String) async -> FrameDescription? {
        .init(app: app, document: document, activity: "Reviewing a synthetic document.", visibleSecrets: true)
    }
}
private actor ScreenGateRedactor: ScreenFrameRedacting {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func redact(_ frame: CapturedScreenFrame, context: ScreenContext) async throws -> CoveredScreenFrame {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return .init(frame: .init(.init(heic: Data([1,2,3]), width: 100, height: 100, boxes: [], appName: "Fixture", windowTitle: "Synthetic")), text: "Safe text", lineCount: 1)
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct ScreenFastRedactor: ScreenFrameRedacting {
    func redact(_ frame: CapturedScreenFrame, context: ScreenContext) async throws -> CoveredScreenFrame {
        .init(frame: .init(.init(heic: try FrameRedactor.heic(frame.image), width: frame.image.width, height: frame.image.height, boxes: [], appName: "Fixture", windowTitle: "Synthetic")), text: "Safe fixture text", lineCount: 1)
    }
}
private struct ScreenFastDescriber: ScreenDescribing {
    func describe(_ covered: CoveredScreenFrame) async -> Redacted<JournalPayload> { .init(.init(description: "A synthetic description")) }
}
@MainActor private final class ScreenFixtureSource: ScreenCapturing {
    var hasPermission = true
    var captures = 0
    var requests = 0
    let image: CGImage
    init() throws { image = try ScreenTestImages.draw() }
    func requestPermission() -> Bool { requests += 1; return hasPermission }
    func capture(_ context: ScreenContext) async throws -> CapturedScreenFrame { captures += 1; return .init(image: image) }
}
@MainActor private final class ScreenFixture {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var policy = ScreenPolicy(enabled: true, consented: true)
    var context = ScreenContext(bundleID: "com.example.Editor", appName: "Fixture", windowTitle: "Synthetic", windowID: 1, processID: 42)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2b_" + UUID().uuidString)
    let source: ScreenFixtureSource
    let journal: EncryptedJournalStore
    var observer: ScreenObserver!
    init(processor: (any ScreenFrameRedacting)? = nil, describer: (any ScreenDescribing)? = nil) throws {
        source = try ScreenFixtureSource(); journal = .init(root: root, keyProvider: FixtureJournalKey())
        observer = ScreenObserver(journal: journal, redactor: LocalRedactor(useOnDeviceModel: false), policy: { [unowned self] in policy },
            context: { [unowned self] in context }, source: source, processor: processor ?? ScreenFastRedactor(),
            describer: describer ?? ScreenFastDescriber(), clock: { [unowned self] in now })
    }
    func close() { observer.stop(); try? FileManager.default.removeItem(at: root) }
    func finish(_ count: Int = 2) async throws {
        for _ in 0..<200 {
            if try journal.items(matching: .init()).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Screen fixture did not commit expected rows; pause=\(String(describing: observer.pause)), error=\(String(describing: observer.lastError))")
    }
}
@Suite @MainActor struct ScreenLearningTests {
    @Test func unchangedAndScrolledFingerprints() throws {
        let base = try ScreenFingerprint(image: ScreenTestImages.draw())
        #expect(try ScreenFingerprint(image: ScreenTestImages.draw()).isUnchanged(from: base))
        #expect(try !ScreenFingerprint(image: ScreenTestImages.draw(scroll: 8)).isUnchanged(from: base))
    }
    @Test func syntheticBankRedactionSurvivesEncodingAndReOCR() async throws {
        let image = try ScreenTestImages.draw(bank: true)
        let original = try FrameRedactor.textLines(image).map(\.0).joined(separator: "\n")
        #expect(original.contains("4401")); #expect(original.contains("example.person@example.com"))
        let context = ScreenContext(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Synthetic bank", windowID: 1, processID: 1)
        let covered = try await FrameRedactor(redactor: LocalRedactor(useOnDeviceModel: false)).redact(.init(image: image), context: context)
        let source = try #require(CGImageSourceCreateWithData(covered.frame.value.heic as CFData, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let final = try FrameRedactor.textLines(output).map(\.0).joined(separator: "\n")
        for privateText in ["4401", "2233", "9876", "12,480", "example.person", "123456789", "4242"] { #expect(!final.contains(privateText)) }
        #expect(covered.frame.value.boxes.filter { $0.kind == .text }.count >= 5)
        #expect(!covered.text.contains("4401"))
        if ProcessInfo.processInfo.environment["ZEUS_TEST_LM2B_EVIDENCE"] == "1" {
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestFixtures/live/lm2b")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try covered.frame.value.heic.write(to: output.appendingPathComponent("synthetic-bank-covered.heic"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(covered.frame.value.boxes).write(to: output.appendingPathComponent("synthetic-bank-boxes.json"))
        }
    }
    @Test func descriptionFallbackSchemaAndPrivateHint() async throws {
        let value = FrameDescription(app: "Editor", document: "Fixture", activity: "Reviewing text.", visibleSecrets: false)
        #expect(try JSONDecoder().decode(FrameDescription.self, from: JSONEncoder().encode(value)) == value)
        let covered = CoveredScreenFrame(frame: .init(.init(heic: Data(), width: 1, height: 1, boxes: [], appName: "Editor", windowTitle: "Synthetic")), text: "Some safe words", lineCount: 1)
        let fallback = await FrameDescriber(redactor: LocalRedactor(useOnDeviceModel: false), model: ScreenNoModel()).describe(covered)
        #expect(fallback.value.description.contains("Text on screen")); #expect(!fallback.value.description.contains("Some safe words"))
        let privateResult = await FrameDescriber(redactor: LocalRedactor(useOnDeviceModel: false), model: ScreenFixedModel()).describe(covered)
        #expect(privateResult.value.details["picture_not_kept"] == "private")
    }
    @Test(arguments: ["disabled", "consent", "permission", "private", "locked", "secure", "camera", "mirror", "presentation", "bank", "privateList", "deny", "allow", "cap"])
    func hardStopsNeverCapture(reason: String) async throws {
        let f = try ScreenFixture(); defer { f.close() }
        switch reason {
        case "disabled": f.policy.enabled = false
        case "consent": f.policy.consented = false
        case "permission": f.source.hasPermission = false
        case "private": f.context.isPrivate = true
        case "locked": f.context.isLocked = true
        case "secure": f.context.secureInput = true
        case "camera": f.context.cameraInUse = true
        case "mirror": f.context.isMirrored = true
        case "presentation": f.context.isPresenting = true
        case "bank": f.context.bundleID = "com.example.banking"
        case "privateList": f.policy.privateApps = [f.context.bundleID]
        case "deny": f.policy.apps = [f.context.bundleID]
        case "allow": f.policy.scope = .onlyChosen
        default: f.policy.capturesPerHour = 0
        }
        f.observer.start(); f.observer.captureNow()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.source.captures == 0); #expect(try f.journal.items(matching: .init()).isEmpty); #expect(f.observer.pause != nil)
    }
    @Test(arguments: ["disabled", "private", "secure", "camera", "mirror", "lock", "delete"])
    func suspendedRedactionCannotCommitAfterBoundary(reason: String) async throws {
        let gate = ScreenGateRedactor(), f = try ScreenFixture(processor: gate); defer { f.close() }
        f.observer.start(); for _ in 0..<30 { await Task.yield() }; f.observer.captureNow()
        for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        switch reason {
        case "disabled": f.policy.enabled = false
        case "private": f.context.isPrivate = true
        case "secure": f.context.secureInput = true
        case "camera": f.context.cameraInUse = true
        case "mirror": f.context.isMirrored = true
        case "lock": f.context.isLocked = true
        default: f.observer.invalidatePendingCapture(); try f.journal.delete(.all)
        }
        await gate.release()
        for _ in 0..<30 { await Task.yield() }
        #expect(try f.journal.items(matching: .init()).isEmpty)
    }
    @Test func dwellPeriodicIdleCapAndRevocation() async throws {
        let f = try ScreenFixture(); defer { f.close() }
        f.observer.start(); for _ in 0..<30 { await Task.yield() }
        f.now.addTimeInterval(9); f.observer.tick(); #expect(f.source.captures == 0)
        f.now.addTimeInterval(1); f.observer.tick(); try await f.finish(); #expect(f.source.captures == 1)
        f.now.addTimeInterval(300); f.observer.tick()
        try await Task.sleep(for: .milliseconds(30)); #expect(f.source.captures == 2)
        #expect(try f.journal.items(matching: .init()).count == 2) // identical preview skipped
        f.context.windowTitle = "Another document"; f.observer.contextDidChange(returnedFromIdle: false)
        for _ in 0..<30 { await Task.yield() }; f.now.addTimeInterval(10); f.observer.tick(); try await f.finish(4)
        f.policy.capturesPerHour = 2; f.observer.captureNow(); #expect(f.observer.pause == .cap)
        f.now.addTimeInterval(3601); f.context.windowTitle = "After a break"; f.observer.contextDidChange(returnedFromIdle: true)
        try await f.finish(6)
        f.source.hasPermission = false; f.observer.tick(); #expect(f.observer.permission == .revoked)
        #expect(try f.journal.items(matching: .init()).contains { $0.payload.value.description.contains("permission") })
    }
    @Test func framesEncryptedDeletedIndependentlyAndRetainedByKind() throws {
        let f = try ScreenFixture(); defer { f.close() }
        let date = f.now.addingTimeInterval(-8*86400)
        let frame = Redacted(FrameItem(heic: Data([1,2,3]), width: 100, height: 100, boxes: [], appName: "Fixture", windowTitle: "Synthetic"))
        let row = JournalItem(id: "frame", time: date, level: .screen, app: f.context.bundleID, kind: .frame, payload: .init(.init(description: "Covered frame")))
        try f.journal.appendFrame(frame, item: row)
        try f.journal.append(.init(id: "description", time: date, level: .screen, kind: .description, payload: .init(.init(description: "Safe screen description", details: ["frame_id": "frame"]))))
        #expect(try f.journal.frame(id: "frame") == frame)
        let files = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        let ciphertext = try Data(contentsOf: #require(files.first { $0.pathExtension == "zframe" }))
        #expect(!String(decoding: ciphertext, as: UTF8.self).contains("Synthetic"))
        #expect(!String(decoding: try f.journal.export(matching: .init()), as: UTF8.self).contains("heic"))
        try f.journal.prune(retention: .init(), now: f.now)
        #expect(try f.journal.frame(id: "frame") == nil)
        #expect(try f.journal.items(matching: .init()).map(\.id) == ["description"])
        #expect(try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zframe" }.isEmpty)
        try f.journal.appendFrame(frame, item: row); try f.journal.delete(.item("frame")); #expect(try f.journal.frame(id: "frame") == nil)
        try f.journal.appendFrame(frame, item: row); try f.journal.delete(.app(f.context.bundleID)); #expect(try f.journal.frame(id: "frame") == nil)
        try f.journal.appendFrame(frame, item: row); try f.journal.delete(.day(date)); #expect(try f.journal.frame(id: "frame") == nil)
        try f.journal.appendFrame(frame, item: row); try f.journal.delete(.all); #expect(try f.journal.frame(id: "frame") == nil)
    }
    @Test func deferredDescriptionsResumeFromCoveredStoredPixelsAndCapSurvivesRelaunch() async throws {
        let f = try ScreenFixture(); defer { f.close() }
        f.policy.deferDescriptions = true; f.observer.start(); for _ in 0..<30 { await Task.yield() }
        f.observer.captureNow(); try await f.finish(1)
        #expect(try f.journal.items(matching: .init()).map(\.kind) == [.frame])
        f.policy.deferDescriptions = false; f.observer.contextDidChange(returnedFromIdle: false)
        try await f.finish(2)
        #expect(try f.journal.items(matching: .init()).contains { $0.kind == .description })
        f.observer.stop(); f.policy.capturesPerHour = 1
        f.observer.start(); f.observer.captureNow(); #expect(f.observer.pause == .cap)
    }
    @Test func privateModelHintKeepsOnlyDescription() async throws {
        let f = try ScreenFixture(describer: FrameDescriber(redactor: LocalRedactor(useOnDeviceModel: false), model: ScreenFixedModel()))
        defer { f.close() }; f.observer.start(); for _ in 0..<30 { await Task.yield() }
        f.observer.captureNow(); try await f.finish(1)
        let rows = try f.journal.items(matching: .init())
        #expect(rows.map(\.kind) == [.description]); #expect(rows.first?.payload.value.details["picture_not_kept"] == "private")
    }
    @Test func sensitiveDialogsAreDroppedBeforeStorage() {
        #expect(FrameRedactor.isSensitiveDialog(title: "Authentication required", text: "Synthetic"))
        #expect(FrameRedactor.isSensitiveDialog(title: "Fixture", text: "Enter your password to unlock keychain"))
        #expect(!FrameRedactor.isSensitiveDialog(title: "Editor", text: "Writing a synthetic document"))
    }
    @Test func permissionIsOnlyRequestedByExplicitConsentedAction() async throws {
        let f = try ScreenFixture(); defer { f.close() }
        f.source.hasPermission = false; f.policy.consented = false; f.observer.start(); f.observer.tick(); f.observer.captureNow()
        #expect(f.source.requests == 0); _ = f.observer.requestPermission(); #expect(f.source.requests == 0)
        f.policy.consented = true; #expect(f.observer.requestPermission() == .denied); #expect(f.source.requests == 1)
    }
    @Test func demandReturnsSafeLocalFrameReusesUnchangedAndNeverRestoresDeletedPicture() async throws {
        let f = try ScreenFixture(); defer { f.close() }
        f.observer.start()
        let first = try #require(await f.observer.captureOnDemand())
        #expect(first.identity.windowID == f.context.windowID); #expect(first.frame?.value.windowTitle == "Synthetic")
        let second = try #require(await f.observer.captureOnDemand())
        #expect(second.frameID == first.frameID); #expect(try f.journal.items(matching: .init()).count == 2)
        try f.journal.delete(.item(try #require(first.frameID)))
        let deleted = try #require(await f.observer.captureOnDemand())
        #expect(deleted.frame == nil); #expect(deleted.frameID == nil); #expect(deleted.descriptionID != nil)
        f.context.isPrivate = true; #expect(await f.observer.captureOnDemand() == nil)
    }
    @Test func finalAllowedDemandSucceedsAndScreenRetentionNeverChangesOtherLevels() async throws {
        let f = try ScreenFixture(); defer { f.close() }; f.policy.capturesPerHour = 1
        f.observer.start(); #expect(await f.observer.captureOnDemand() != nil)
        #expect(await f.observer.captureOnDemand() == nil)
        try f.journal.append(.init(id: "activity-old", time: f.now.addingTimeInterval(-200*86400), level: .activity, kind: .activity, payload: .init(.init(description: "Activity retention is owned by its level"))))
        try f.journal.append(.init(id: "screen-old", time: f.now.addingTimeInterval(-8*86400), level: .screen, kind: .description, payload: .init(.init(description: "Old screen description"))))
        try f.journal.pruneScreens(descriptionDays: 7, now: f.now)
        let ids = try f.journal.items(matching: .init()).map(\.id)
        #expect(ids.contains("activity-old")); #expect(!ids.contains("screen-old"))
    }
    @Test func summarySamplesDescriptionsNeverFrames() {
        let rows = (0..<10).map { JournalItem(id: "\($0)", level: .screen, kind: .description, payload: .init(.init(description: "Description \($0)"))) }
        let frame = JournalItem(level: .screen, kind: .frame, payload: .init(.init(description: "NEVER IMAGE METADATA")))
        let summary = LearnFromMe.screenSummary(rows + [frame])
        #expect(summary == "Description 0 · Description 3 · Description 6 · Description 9")
        #expect(!summary.contains("IMAGE"))
    }
}
