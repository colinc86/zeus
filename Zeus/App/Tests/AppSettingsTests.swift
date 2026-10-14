import Foundation
import Testing
import ZeusProtocol
import ZeusSprites
@testable import Zeus

@MainActor
struct AppSettingsTests {
    @Test func settingsPersistCharacterSizeAndRoutingAndRejectUnknownCharacters() throws {
        let suite = "zeus-settings-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("missing", forKey: "character.id")
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.currentCharacterID == "zeus")
        settings.currentCharacterID = "not-installed"
        #expect(settings.currentCharacterID == "zeus")
        settings.currentCharacterID = "zeus"
        settings.avatarSize = .large
        settings.assistantSessionKey = "claude:/assistant"
        let reloaded = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(reloaded.currentCharacterID == "zeus")
        #expect(reloaded.avatarSize == .large)
        #expect(reloaded.assistantSessionKey == "claude:/assistant")
        settings.assistantSessionKey = nil
        #expect(AppSettings(defaults: defaults, userDirectory: nil).assistantSessionKey == nil)
    }

    @Test func scalesRoundToWholePointsAndNeverBelowTwo() {
        #expect(AvatarSize.small.scale(preferred: 3) == 2)
        #expect(AvatarSize.medium.scale(preferred: 3) == 3)
        #expect(AvatarSize.large.scale(preferred: 3) == 4)
        #expect(AvatarSize.small.scale(preferred: 4) == 3)
        #expect(AvatarSize.medium.scale(preferred: 4) == 4)
        #expect(AvatarSize.large.scale(preferred: 4) == 5)
        #expect(AvatarSize.small.scale(preferred: 1) == 2)
    }

    @Test func quietHoursCoverOvernightDaytimeAndBoundaries() throws {
        let suite = "zeus-quiet-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        func date(_ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: hour)))
        }
        #expect(!settings.isQuiet(at: try date(23), calendar: calendar))
        settings.quietHoursEnabled = true
        #expect(settings.isQuiet(at: try date(22), calendar: calendar))
        #expect(settings.isQuiet(at: try date(6), calendar: calendar))
        #expect(!settings.isQuiet(at: try date(7), calendar: calendar))
        settings.quietStartHour = 9; settings.quietEndHour = 17
        #expect(settings.isQuiet(at: try date(9), calendar: calendar))
        #expect(!settings.isQuiet(at: try date(17), calendar: calendar))
        settings.quietEndHour = 9
        #expect(settings.isQuiet(at: try date(0), calendar: calendar))
    }

    @Test func spriteScaleAndCharacterChangesKeepGlobalAnchor() {
        let point = CGPoint(x: -750, y: 400)
        let frame = SpriteLayout.frame(at: point, canvas: PixelSize(width: 48, height: 56),
                                       anchor: PixelPoint(x: 24, y: 53), scale: 3)
        #expect(frame.size == CGSize(width: 144, height: 168))
        #expect(frame.origin == CGPoint(x: -822, y: 391))
        let resized = SpriteLayout.frame(at: point, canvas: PixelSize(width: 24, height: 32),
                                         anchor: PixelPoint(x: 12, y: 32), scale: 5)
        #expect(resized.midX == point.x)
        #expect(resized.minY == point.y)
        let offset = SpriteLayout.offset(canvas: PixelSize(width: 48, height: 56), anchor: PixelPoint(x: 24, y: 53), scale: 3)
        #expect(CGPoint(x: frame.minX + offset.x, y: frame.minY + offset.y) == point)
    }

    @Test func attachmentPathsExpandTildeAndLinksRequireWebScheme() throws {
        let local = Attachment(kind: .file, label: "file", target: "~/Documents/notes.txt")
        #expect(AttachmentTarget.url(for: local)?.path == NSHomeDirectory() + "/Documents/notes.txt")
        #expect(AttachmentTarget.url(for: Attachment(kind: .folder, label: "folder", target: "/tmp"))?.isFileURL == true)
        #expect(AttachmentTarget.url(for: Attachment(kind: .url, label: "site", target: "https://example.com")) != nil)
        #expect(AttachmentTarget.url(for: Attachment(kind: .url, label: "script", target: "javascript:alert(1)")) == nil)
        #expect(AttachmentTarget.url(for: Attachment(kind: .url, label: "invalid", target: "https:")) == nil)
        #expect(AttachmentTarget.url(for: Attachment(kind: .file, label: "relative", target: "notes.txt")) == nil)
    }
}
