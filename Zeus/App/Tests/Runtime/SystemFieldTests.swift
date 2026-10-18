import Foundation
import Testing
@testable import Zeus

private actor WarpProse: ProseRedacting {
    var inputs: [String] = []
    func spans(in text: String) async -> [ProsePrivateSpan]? {
        inputs.append(text)
        return [.init(text: "Warp", kind: .health), .init(text: "onDeviceModel", kind: .secret)]
    }
}
private struct WarpStringRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> {
        .init(text.replacingOccurrences(of: "Warp", with: "‹name›"))
    }
}

@Suite struct SystemFieldTests {
    @Test func onlyUserValuesEnterTheModelAndKeysNeverChange() async throws {
        let model = WarpProse(), redactor = LocalRedactor(prose: model)
        let payload = JournalPayload(description: "Working in Warp", text: "Warp", topic: "Warp",
            details: ["appName": "Warp", "name": "Warp", "frame_id": "frame-secret-value",
                      "descriptionEngine": "onDeviceModel", "window": "Warp", "Warp": "Warp",
                      "url": "Warp", "document": "Warp", "newUnknownField": "Warp"])
        let safe = await redactor.redact(payload)
        for key in ["appName", "name", "frame_id", "descriptionEngine"] {
            #expect(safe.value.details[key] == payload.details[key])
        }
        for key in ["window", "Warp", "url", "document", "newUnknownField"] {
            #expect(safe.value.details[key]?.contains("Warp") == false)
        }
        #expect(safe.value.description.contains("Warp") == false)
        #expect(safe.value.text?.contains("Warp") == false)
        #expect(safe.value.topic?.contains("Warp") == false)
        #expect(Set(safe.value.details.keys) == Set(payload.details.keys))
        let input = try #require(await model.inputs.first)
        #expect(!input.contains("appName") && !input.contains("frame-secret-value") && !input.contains("onDeviceModel"))
        #expect(await model.inputs.count == 1)
    }

    @Test func everyAllowlistedFactBypassesBothPassesAndDefaultRedactorMatches() async {
        let details = Dictionary(uniqueKeysWithValues: JournalPayload.systemDetailKeys.map { ($0, "Warp") })
        let model = WarpProse()
        let payload = JournalPayload(description: "", details: details)
        let local = await LocalRedactor(prose: model).redact(payload)
        let fallback = await WarpStringRedactor().redact(payload)
        #expect(local.value.details == details)
        #expect(fallback.value.details == details)
        #expect(await model.inputs.isEmpty)
        let unknown = await WarpStringRedactor().redact(.init(description: "Warp", details: ["window": "Warp"]))
        #expect(unknown.value.description == "‹name›")
        #expect(unknown.value.details["window"] == "‹name›")
    }

    @Test func typingKeepsAppIdentityButStillRequiresSemanticWordRedaction() async throws {
        let run = try #require(await RunRedactor(redactor: LocalRedactor(prose: WarpProse()))
            .redact(words: .init("Reviewing a task in Warp"), app: "Warp"))
        #expect(run.app.value == "Warp")
        #expect(!run.words.value.contains("Warp"))
        #expect(run.words.report.semanticEngine == .onDeviceModel)
    }

    @Test func screenDescriptionRetainsAppAndEngineWhileWindowStaysPrivate() async {
        let frame = FrameItem(heic: Data(), width: 1, height: 1, boxes: [], appName: "Warp", windowTitle: "Warp")
        let covered = CoveredScreenFrame(frame: .init(frame), text: "Synthetic work", lineCount: 1)
        let safe = await FrameDescriber(redactor: LocalRedactor(prose: WarpProse()), model: nil).describe(covered)
        #expect(safe.value.details["appName"] == "Warp")
        #expect(safe.value.details["descriptionEngine"] == "naturalLanguage")
        #expect(safe.value.details["window"]?.contains("Warp") == false)
        #expect(!safe.value.description.contains("Warp"))
    }

    @Test func legacyIdentityRecoveryDoesNotUnredactAnyUserContent() {
        let item = JournalItem(level: .screen, app: "dev.warp.Warp-Stable", kind: .description,
            payload: .init(.init(description: "‹health›", details: ["appName": "‹name›", "window": "‹secret›"])))
        #expect(JournalAppName.displayName(item, resolve: { $0 == "dev.warp.Warp-Stable" ? "Warp" : nil }) == "Warp")
        let unknown = JournalItem(level: .screen, kind: .description, payload: item.payload)
        #expect(JournalAppName.repairedDetails(unknown)["appName"] == "‹name›")
        #expect(JournalAppName.repairedDetails(item)["window"] == "‹secret›")
        #expect(item.payload.value.description == "‹health›")
    }

    @Test func legacySystemAppResolvesThroughLaunchServicesWithoutLaunchingIt() {
        let item = JournalItem(level: .activity, app: "com.apple.finder", kind: .activity,
            payload: .init(.init(description: "Switched to ‹name›", details: ["name": "‹name›", "kind": "activate"])))
        #expect(JournalAppName.displayName(item) == "Finder")
        #expect(ActivityStore.activityEvent(item)?.name == "Finder")
        #expect(item.payload.value.description == "Switched to ‹name›")
    }

    @Test @MainActor func oldNamesHealOnlyExportedIdentityAndFeedReflection() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true); defer { f.stop() }
        let writer = try #require(f.folder)
        writer.enabledLevels = { [.activity, .focus, .screen, .typed] }
        var rows: [JournalItem] = []
        for offset in 0..<3 {
            let time = f.clock.now.addingTimeInterval(Double(offset - 2) * 86400)
            let row = JournalItem(id: "fx12_\(offset)", time: time, level: .focus, app: "org.zeus-fixture.Warp", kind: .focus,
                payload: .init(.init(description: "Editing ‹secret›", details: ["appName": "‹name›", "window": "‹secret›"])))
            rows.append(row); try f.journal.append(row)
        }
        await writer.flush()
        let root = try #require(writer.folderURL)
        let text = try String(contentsOf: root.appendingPathComponent("Zeus/days/2026-10-14/focus.md"), encoding: .utf8)
        #expect(text.contains("appName: Warp"))
        #expect(text.contains("window: ‹secret›"))
        #expect(text.contains("Editing ‹secret›"))
        let digest = ReflectionPatternDigest(time: .init(calendar: FolderFactsTests.calendar),
            day: f.clock.now, levels: [.focus], items: rows, feedback: []).build()
        #expect(digest.text.contains("Warp"))
        #expect(!digest.text.contains("‹name›"))
        let stored = try f.journal.items(matching: .init())
        #expect(stored.allSatisfy { $0.payload.value.details["appName"] == "‹name›" })
    }
}
