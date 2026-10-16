import Foundation
import Observation
import Testing
@testable import Zeus

@MainActor @Observable final class LF1FolderFake: LearningFolderProviding, LearningFolderErasing {
    var managedFolder: URL?
    var ownFolder: URL?
    var folderURL: URL? { managedFolder ?? ownFolder }
    var lastWriteError: String?
    var files: [String: URL] = [:]
    var erased: [Bool] = []
    var beforeErase: () -> Void = {}
    func setFolder(_ folder: URL?) { ownFolder = folder }
    func fileURL(forJournalItem item: JournalItem) -> URL? { files[item.id] }
    func deleteFolderContents(includeAssistantNotes: Bool) throws { beforeErase(); erased.append(includeAssistantNotes) }
}

@MainActor struct LF1AppTests {
    @Test func coveringDefaultsOnRequiresConfirmationAndPersistsOnlyAfterConfirming() throws {
        let name = "lf1-cover-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearnSettings(defaults: defaults)
        let model = ScreenPrivacyModel(policies: ObservationSettings(defaults: defaults), privacy: settings)
        var changes = 0; model.changed = { changes += 1 }
        #expect(settings.coverPictures)
        model.setCoverPictures(false)
        #expect(model.showsCoveringConfirmation && settings.coverPictures && changes == 0)
        model.keepCovering(); model.confirmUncoveredPictures()
        #expect(settings.coverPictures && changes == 0)
        model.setCoverPictures(false); model.confirmUncoveredPictures()
        #expect(!settings.coverPictures && !model.showsCoveringConfirmation && changes == 1)
        #expect(!LearnSettings(defaults: defaults).coverPictures)
        model.setCoverPictures(true)
        #expect(settings.coverPictures && !model.showsCoveringConfirmation && changes == 2)
    }
    @Test func folderChoiceCancelStopManagedPrecedenceAndErrors() {
        let fake = LF1FolderFake(), model = LearningFolderModel()
        model.provider = fake
        #expect(model.path == nil && !model.writeFailed)
        model.pickFolder = { nil }; model.choose(); #expect(fake.ownFolder == nil)
        let own = URL(fileURLWithPath: "/fixture/own"), managed = URL(fileURLWithPath: "/fixture/managed")
        model.pickFolder = { own }; model.choose(); #expect(model.folderURL == own)
        fake.managedFolder = managed; #expect(model.folderURL == managed)
        model.stopKeepingFolder(); #expect(fake.ownFolder == nil && model.folderURL == managed)
        fake.managedFolder = nil; #expect(model.folderURL == nil)
        fake.lastWriteError = "fixture failure"; #expect(model.writeFailed)
        fake.lastWriteError = nil; #expect(!model.writeFailed)
    }
    @Test func finderUsesExistingSeamFilesAndDayIgnoresSearchFilters() throws {
        let journal = LM2JournalFake(), fake = LF1FolderFake(), folder = LearningFolderModel(provider: fake)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = JournalItem(id: "kept", time: now, level: .activity, kind: .activity, payload: .init(.init(description: "Fixture")))
        try journal.append(item)
        let model = JournalViewerModel(journal: journal, now: now); model.folder = folder
        var revealed: [URL] = []; folder.reveal = { revealed.append($0) }; model.revealFiles = { revealed += $0 }
        folder.show(item); model.showDayInFinder(); #expect(revealed.isEmpty)
        let url = URL(fileURLWithPath: "/fixture/Zeus/days/2027-01-15/activity.md")
        fake.files[item.id] = url
        model.search = "no match"; model.level = 4
        #expect(model.items.isEmpty && model.dayFiles == [url])
        folder.show(item); model.showDayInFinder(); #expect(revealed == [url, url])
        fake.files = [:]; model.showDayInFinder(); #expect(revealed == [url, url])
    }
    @Test func deleteEverythingDefaultsToKeepingNotesAndPassesExplicitChoiceAfterJournalErasure() throws {
        let name = "lf1-delete-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        let model = LearningPresentation(defaults: defaults, learn: learn)
        defer { model.stop() }
        let journal = LM2JournalFake(), fake = LF1FolderFake()
        model.folder.provider = fake
        model.install(journal: journal, rules: LM2RulesFake(), redactor: LocalRedactor(useOnDeviceModel: false), source: LM2FocusSource())
        try journal.append(.init(level: .activity, kind: .activity, payload: .init(.init(description: "Fixture"))))
        fake.beforeErase = { #expect((try? journal.items(matching: .init()).isEmpty) == true) }
        model.deleteEverything(); #expect(fake.erased == [false])
        model.deleteEverything(includeAssistantNotes: true); #expect(fake.erased == [false, true])
        journal.fails = true
        model.deleteEverything(includeAssistantNotes: true)
        #expect(fake.erased == [false, true]); #expect(model.error != nil)
    }
}
