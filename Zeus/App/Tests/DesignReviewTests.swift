import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
import ZeusSprites
@testable import Zeus

@MainActor struct DesignReviewTests {
    @Test(arguments: [3, 4, 5])
    func sharedArtRectKeepsScreenViewAndWarningCoordinatesAligned(_ scale: Int) {
        let rect = AvatarArtRect(canvas: PixelSize(width: 40, height: 50), pixels: CGRect(x: 3, y: 8, width: 27, height: 25), scale: scale)
        let s = CGFloat(scale)
        #expect(rect.topLeft == CGRect(x: 3 * s, y: 17 * s, width: 27 * s, height: 25 * s))
        #expect(rect.badgeCorner == CGPoint(x: 30 * s + 4, y: 17 * s - 4))
        #expect(rect.warningTopLeft.origin == CGPoint(x: 3 * s - 4, y: 17 * s - 4))
        #expect(rect.warningTopLeft.size == CGSize(width: 18, height: 18)) // Native UI size never scales with the sprite.
        let origin = CGPoint(x: -700, y: 90)
        #expect(rect.screenRect(canvasOrigin: origin) == rect.bottomLeft.offsetBy(dx: origin.x, dy: origin.y))
        let bounds = CGRect(origin: .zero, size: rect.canvasSize)
        let flipped = rect.warningFrame(in: bounds, flipped: true)
        let native = rect.warningFrame(in: bounds, flipped: false)
        #expect(flipped == rect.warningTopLeft)
        #expect(native.minX == flipped.minX && native.maxY == bounds.height - flipped.minY)
        #expect(native.maxY == rect.bottomLeft.maxY + 4)
        #expect(native.size == rect.warningTopLeft.size)
        let shifted = rect.warningFrame(in: bounds.offsetBy(dx: 7, dy: 9), flipped: false)
        #expect(shifted == native.offsetBy(dx: 7, dy: 9))
    }

    @Test func badgeCornerStaysInsideTheCanvasWhenTheArtTouchesItsEdges() {
        let rect = AvatarArtRect(canvas: PixelSize(width: 40, height: 50), pixels: CGRect(x: 10, y: 0, width: 30, height: 50), scale: 2)
        #expect(rect.badgeCorner == CGPoint(x: 80, y: 0))
    }

    /// The avatar window is exactly the canvas: the whole badge must land inside it, its trailing edge on the corner.
    @Test(arguments: ["ghost", "zeus", "bat"])
    func unreadBadgeDrawsWholeInsideTheAvatarWindow(_ id: String) async throws {
        let suite = "zeus-badge-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.avatarSize = .small
        settings.currentCharacterID = id
        let character = try #require(settings.currentCharacter)
        let layout = AvatarArtLayout()
        layout.rect = AvatarArtRect(canvas: character.canvasSize, pixels: SpriteLayout.artBounds(character: character), scale: settings.pixelScale)
        let host = NSHostingView(rootView: SpriteAvatarView(settings: settings, status: AvatarStatusModel(cards: cards),
                                                             messaging: AgentMessagingHub(), artLayout: layout, activity: SurfaceActivity()))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -24000, y: -24000), size: layout.rect.canvasSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        func snapshot() async throws -> (bytes: [UInt8], row: Int, wide: Int) {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return ([UInt8](UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh)), rep.bytesPerRow, rep.pixelsWide)
        }
        let without = try await snapshot().bytes
        cards.add(Card(kind: .message, body: "Unread"))
        let (with, row, wide) = try await snapshot()
        let scale = CGFloat(wide) / layout.rect.canvasSize.width
        var minX = Int.max, maxX = -1
        // New pixels in the badge's fill color (the sprite may change state too, so a plain diff isn't enough).
        let fill = try #require(NSColor(ZeusPalette.dark.badge).usingColorSpace(.deviceRGB))
        let target = [fill.redComponent, fill.greenComponent, fill.blueComponent].map { Int(($0 * 255).rounded()) }
        func isFill(_ i: Int) -> Bool { (0..<3).allSatisfy { abs(Int(with[i + $0]) - target[$0]) <= 12 } && with[i + 3] > 200 }
        for i in stride(from: 0, to: with.count, by: 4) where (i % row) / 4 < wide && with[i..<i + 4] != without[i..<i + 4] && isFill(i) {
            minX = min(minX, (i % row) / 4); maxX = max(maxX, (i % row) / 4)
        }
        try #require(maxX >= 0, "\(id): the badge didn't draw")
        let corner = layout.rect.badgeCorner
        #expect(abs(CGFloat(maxX + 1) / scale - corner.x) <= 2, "\(id): badge fill ends at \(CGFloat(maxX + 1) / scale), corner \(corner.x)")
        #expect(CGFloat(maxX - minX + 1) / scale >= 15, "\(id): only \(CGFloat(maxX - minX + 1) / scale) pt of the badge is visible")
    }

    @Test func bothDialogFormsAttachToTheSilhouetteInsteadOfCanvasHeadroom() {
        let rect = AvatarArtRect(canvas: PixelSize(width: 40, height: 50), pixels: CGRect(x: 3, y: 8, width: 27, height: 25), scale: 3)
        let origin = CGPoint(x: 600, y: 100)
        let art = rect.screenRect(canvasOrigin: origin)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 1000)
        let anchor = CGPoint(x: 660, y: 110)
        let dialog = DialogPlacement.place(art: art, anchor: anchor, size: CGSize(width: 380, height: 400), screen: screen)
        let peek = PeekPlacement.place(art: art, anchorX: anchor.x, contentSize: CGSize(width: 280, height: 150), screen: screen)
        #expect(dialog.tail.edge == .bottom && peek.tail.edge == .bottom)
        #expect(abs(dialog.frame.minY - (art.maxY + 4)) <= 1) // Dialog chrome snaps to its 2 pt grid.
        #expect(abs(peek.frame.minY - dialog.frame.minY) <= 1)
        #expect(dialog.frame.minY < origin.y + rect.canvasSize.height)
        #expect(abs(dialog.frame.minX + dialog.tail.offset - anchor.x) <= 1)
    }

    @Test func lateAnswerCaptionAppearsOnlyWhenSeparatedFromItsSource() {
        let question = Card(id: "question", kind: .question, title: "Ship the build?", body: "Ready?", options: [CardOption(id: "no", label: "No")])
        let later = Card(id: "later", kind: .message, body: "More context")
        let answer = ConversationEntry(id: "answer", timestamp: Date(), content: .userAnswer(cardID: question.id, response: CardResponse(optionID: "no", device: .ios)))
        let source = ConversationEntry(id: "source", timestamp: Date(), content: .agentCard(question))
        let other = ConversationEntry(id: "other", timestamp: Date(), content: .agentCard(later))
        #expect(ConversationLayout.answerCaption(answer, after: source, cards: [question, later]) == nil)
        #expect(ConversationLayout.answerCaption(answer, after: other, cards: [question, later]) == "Ship the build?")
        #expect(ConversationLayout.answerCaption(answer, after: nil, cards: [question]) == "Ship the build?") // Question can be on an older page.
        #expect(ConversationLayout.answerCaption(source, after: other, cards: [question]) == nil)
        #expect(ConversationLayout.answerCaption(answer, after: other, cards: []) == nil)
        var untitled = question; untitled.title = nil; untitled.body = String(repeating: "👩🏽‍💻", count: 45)
        #expect(ConversationLayout.answerCaption(answer, after: other, cards: [untitled]) == String(untitled.body.prefix(40)))
    }

    @Test(arguments: [(false, false), (true, false), (true, true)])
    func staticPeekTextKeepsTalkingForOnePointTwoSeconds(_ flags: (Bool, Bool)) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-static-speech-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let status = AvatarStatusModel(cards: store, clock: { clock.now })
        let card = Card(kind: .message, body: "A short message", mood: .happy)
        status.notePeek(card, reduceMotion: flags.0, typewriter: flags.1)
        clock.advance(1.199); status.tick()
        #expect(status.state == .talking)
        clock.advance(0.001); status.tick()
        #expect(status.state == .happy)
    }

    @Test func threadRevealFinishesWithinTwoPointFourSecondsWithoutSplittingGraphemes() {
        let clock = TestClock()
        let model = TypewriterModel(clock: { clock.now })
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 600)
        model.configure(text: text, animate: true)
        clock.advance(1.2); model.tick()
        #expect(model.visibleCount == 300)
        clock.advance(1.2); model.tick()
        #expect(model.visibleCount == 600 && !model.isRevealing)
        model.configure(text: "Short text", animate: true)
        clock.advance(0.125); model.tick()
        #expect(model.visibleCount == 5)
    }

    @Test func peekErrorStaysOnTheSideAwayFromTheAvatar() {
        #expect(PeekView.errorComesFirst(edge: .bottom))
        for edge in [ZeusDialogTail.Edge.top, .leading, .trailing] { #expect(!PeekView.errorComesFirst(edge: edge)) }
    }

    @Test func characterMenuSeparatesUserCharactersButKeepsOverridesInRosterOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-character-menu-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = try #require(CharacterLibrary.bundledDirectory)
        let source = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("zeus.json"))) as? [String: Any])
        for (id, name) in [("user-zeus", "User Zeus"), ("ghost", "Overridden Ghost")] {
            var file = source; file["id"] = id; file["name"] = name
            try JSONSerialization.data(withJSONObject: file).write(to: root.appendingPathComponent(id + ".json"))
        }
        let suite = "zeus-character-menu-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: root)
        let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("cards-history.data")), settings: settings)
        let menu = shell.makeContextMenu()
        let items = try #require(menu.items.first { $0.title == "Character" }?.submenu).items
        #expect(items.filter(\.isSeparatorItem).count == 1)
        #expect(items.prefix(12).compactMap { $0.identifier?.rawValue.replacingOccurrences(of: "character:", with: "") } == CharacterLibrary.bundledOrder)
        #expect(items[1].title == "Overridden Ghost")
        #expect(items[12].isSeparatorItem)
        #expect(items[13].identifier?.rawValue == "character:user-zeus")
        let bundled = AppSettings(defaults: defaults, userDirectory: nil)
        let builtinShell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("other-history.data")), settings: bundled)
        let builtinItems = try #require(builtinShell.makeContextMenu().items.first { $0.title == "Character" }?.submenu).items
        let hasSeparator = builtinItems.contains { $0.isSeparatorItem }
        #expect(!hasSeparator)
    }
}
