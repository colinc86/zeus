import AppKit
import Foundation
import Testing
@testable import Zeus

@MainActor final class LM2BPrivateKey: JournalKeyProviding {
    func key() throws -> Data { Data(repeating: 86, count: 32) }
}
@MainActor struct LM2BViewerTests {
    @Test func pairedPictureUsesExactStoredDescriptionAndDeletionUndoIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-picture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey()), now = Date()
        let image = try FrameRedactor.heic(ScreenTestImages.draw())
        let frame = Redacted(FrameItem(heic: image, width: 1000, height: 600,
            boxes: [.init(x: 0.1, y: 0.1, width: 0.2, height: 0.1, kind: .text)], appName: "Fixture", windowTitle: "Example.swift"))
        try journal.appendFrame(frame, item: .init(id: "frame", time: now, level: .screen, app: "test.editor", kind: .frame,
            payload: .init(.init(description: "Fixture · Example.swift", details: ["window": "Example.swift"]))))
        let description = JournalItem(id: "description", time: now, level: .screen, app: "test.editor", kind: .description,
            payload: .init(.init(description: "Reviewing ‹name›'s changes.", details: ["frame_id": "frame", "window": "Example.swift"])))
        try journal.append(description)
        let viewer = JournalViewerModel(journal: journal, now: now, clock: { now })
        #expect(viewer.items.count == 2); #expect(viewer.timeline.count == 1)
        let picture = try #require(viewer.pictures.rows.first)
        #expect(picture.description == description.payload.value.description)
        #expect(viewer.pictures.frame(picture) == frame)
        #expect(viewer.pictures.thumbnail(picture) != nil)
        viewer.pictures.selectedID = picture.id
        var invalidations = 0; viewer.beforeDelete = { invalidations += 1 }
        viewer.pictures.delete(picture, includingDescription: false)
        #expect(invalidations == 1); #expect(try journal.frame(id: "frame") == nil)
        #expect(viewer.pictures.rows.count == 1)
        #expect(viewer.pictures.rows[0].description == description.payload.value.description)
        #expect(viewer.pictures.caption(viewer.pictures.rows[0]) == "Picture deleted by you")
        viewer.pictures.undoDelete()
        #expect(try journal.frame(id: "frame") == frame)
        #expect(viewer.pictures.deleted == nil)
        viewer.pictures.delete(try #require(viewer.pictures.rows.first), includingDescription: true)
        #expect(viewer.pictures.rows.isEmpty); #expect(viewer.pictures.deleted == nil)
        #expect(try journal.items(matching: .init()).isEmpty)
    }
    @Test func searchJoinsDescriptionToFrameAndNavigationStaysInFilteredDay() throws {
        let now = Date(), payload = Redacted(JournalPayload(description: "Stored description", details: ["frame_id": "f"]))
        let frame = JournalItem(id: "f", time: now, level: .screen, kind: .frame, payload: .init(.init(description: "App · window")))
        let description = JournalItem(id: "d", time: now, level: .screen, kind: .description, payload: payload)
        let rows = JournalTimelineRow.grouped([description], catalog: [frame, description])
        guard case .picture(let picture) = try #require(rows.first) else { Issue.record("Expected grouped picture"); return }
        #expect(picture.frameRecord == frame); #expect(picture.descriptionRecord == description)
        let second = JournalPicture(id: "older", frameRecord: .init(id: "older", time: now.addingTimeInterval(-10), level: .screen, kind: .frame, payload: .init(.init(description: "Older"))), descriptionRecord: nil)
        let model = JournalPictureModel(journal: LM2JournalFake())
        model.update([.picture(picture), .picture(second)]); model.selectedID = "f"
        model.step(1); #expect(model.selectedID == "older"); model.step(1); #expect(model.selectedID == "older")
        model.step(-1); #expect(model.selectedID == "f")
        model.update([.picture(second)]); #expect(model.selectedID == nil)
    }
    @Test func expiryReasonsAndSentDescriptionsHaveNoImplicitImageExport() throws {
        let now = Date(), old = now.addingTimeInterval(-8 * 86_400)
        func picture(reason: String?) -> JournalPicture {
            var details = ["frame_id": "f"]
            if let reason { details["picture_not_kept"] = reason }
            return .init(id: "f", frameRecord: nil, descriptionRecord: .init(time: old, level: .screen, kind: .description,
                payload: .init(.init(description: "Covered description", details: details))))
        }
        #expect(picture(reason: nil).missingCaption(now: now) == "Picture deleted after 7 days")
        #expect(picture(reason: "private").missingCaption(now: now) == "Picture not kept: it looked private")
        #expect(picture(reason: "deletedByUser").missingCaption(now: now) == "Picture deleted by you")
        let journal = LM2JournalFake()
        journal.records = [.init(time: now, level: .screen, kind: .sentToAssistant,
            payload: .init(.init(description: "Screen summary", text: "Reviewing changes.", details: ["sessionLabel": "Claude · Fixture"])))]
        let viewer = JournalViewerModel(journal: journal, now: now); viewer.sentOnly = true
        #expect(viewer.pictures.rows.isEmpty); #expect(viewer.items.count == 1)
        let exported = try JSONDecoder().decode([JournalItem].self, from: #require(viewer.export()))
        #expect(exported == journal.records)
    }
}

@MainActor struct LM2ReviewRegressionTests {
    @Test func realPrivateActivityAndAppHeaderHaveDistinctNames() {
        let event = ActivityEvent(t: Date(), kind: .private, seconds: 120)
        let item = JournalItem(time: event.t, level: .activity, kind: .activity, payload: .init(ActivityStore.payload(event)))
        #expect(item.app == nil); #expect(JournalDisplay.name(item) == "Private")
        let own = JournalItem(level: .activity, kind: .reflection, payload: .init(.init(description: "Reflection")))
        #expect(JournalDisplay.name(own) == "Zeus")
        let app = JournalItem(level: .focus, app: "test.editor", kind: .focus, payload: .init(.init(description: "test.editor")))
        #expect(!JournalDisplay.showsDescription(app))
    }
    @Test func scopeCaptionAndRuleTriggersUseApprovedHierarchyAndWords() {
        #expect(ObservationScopeView.scopeCaption(level: 2, scope: .exceptPrivate) == "Apps on your private list (above) are never recorded at any level.")
        #expect(ObservationScopeView.scopeCaption(level: 3, scope: .exceptPrivate) == ObservationScopeView.scopeCaption(level: 2, scope: .exceptPrivate))
        #expect(RulesPaneModel.triggerText(.init(time: .init(startMinute: 1080, endMinute: 540, weekdays: Set(2...6)))) == "Weekdays 18:00–09:00")
        #expect(RulesPaneModel.triggerText(.init(time: .init(startMinute: 0, endMinute: 0, weekdays: [1, 7]))) == "Weekends all day")
        #expect(RulesPaneModel.triggerText(.init(apps: ["editor"], state: "tests failing"), appName: { _ in "Xcode" }) == "in Xcode · when tests failing")
        #expect(RulesPaneModel.triggerText(.init()) == "Any time")
    }
}
