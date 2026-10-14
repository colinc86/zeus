import SwiftUI
import Testing
import ZeusProtocol
@testable import ZeusDesign

@Test func peekButtonLayoutFollowsContract() {
    // ≤ 3 options: inline; text-only: Reply…; options + text: both; > 3 options: Reply… only.
    #expect(ZeusPeekBubble.layout(optionCount: 0, acceptsText: false) == (0, false))
    #expect(ZeusPeekBubble.layout(optionCount: 2, acceptsText: false) == (2, false))
    #expect(ZeusPeekBubble.layout(optionCount: 3, acceptsText: true) == (3, true))
    #expect(ZeusPeekBubble.layout(optionCount: 0, acceptsText: true) == (0, true))
    #expect(ZeusPeekBubble.layout(optionCount: 4, acceptsText: false) == (0, true))
    #expect(ZeusPeekBubble.bodyLineLimit(hasButtons: false) == 3)
    #expect(ZeusPeekBubble.bodyLineLimit(hasButtons: true) == 2)
}

@Test func peekAutoHideMatchesContractFormula() {
    // clamp(4 + words/4, 6, 15); high priority never auto-hides.
    #expect(ZeusPeekTiming.autoHideDelay(words: 0, highPriority: false) == 6)
    #expect(ZeusPeekTiming.autoHideDelay(words: 12, highPriority: false) == 7)
    #expect(ZeusPeekTiming.autoHideDelay(words: 100, highPriority: false) == 15)
    #expect(ZeusPeekTiming.autoHideDelay(words: 12, highPriority: true) == nil)
    #expect(ZeusPeekTiming.wordCount(title: "Talk tomorrow", body: "Have you\\nstarted on it?") == 6)
}

@Test func typewriterIsMonotonicAndBounded() {
    let total = 80
    let duration = ZeusPeekTiming.typingDuration(length: total)
    #expect(duration == 2.0)                                            // 80 / 40 cps
    #expect(ZeusPeekTiming.typingDuration(length: 400) == ZeusPeekTiming.maxTypingDuration)
    var last = -1
    for step in 0...60 {
        let n = ZeusPeekTiming.revealedCount(elapsed: Double(step) * 0.05, total: total)
        #expect(n >= last && n <= total)
        last = n
    }
    #expect(ZeusPeekTiming.revealedCount(elapsed: 0, total: total) == 0)
    #expect(ZeusPeekTiming.revealedCount(elapsed: duration, total: total) == total)
    #expect(ZeusPeekTiming.revealedCount(elapsed: -1, total: total) == 0)
    #expect(ZeusPeekTiming.revealedCount(elapsed: 1, total: 0) == 0)
}

@Test func talkingLastsAsLongAsTheTyping() {
    let length = ZeusPeekTiming.typedLength("Your talk on **Q3 planning** is tomorrow.")
    #expect(length == "Your talk on Q3 planning is tomorrow.".count)    // markdown syntax isn't typed
    #expect(ZeusPeekTiming.typedLength(String(repeating: "a", count: 500)) == ZeusPeekTiming.typedCharacterCap)
    let talking = ZeusPeekTiming.talkingDuration(length: length, reduceMotion: false)
    #expect(talking == ZeusPeekTiming.typingDuration(length: length) + ZeusPeekTiming.talkTail)
    #expect(ZeusPeekTiming.talkingDuration(length: length, reduceMotion: true) == 1.2)
}

@Test func typewriterPrefixKeepsMarkdownStyling() {
    let full = ZeusPeekBubble.markdown("Hi **there**")
    let part = ZeusPeekBubble.prefix(full, count: 5)
    #expect(String(part.characters) == "Hi th")
    #expect(String(ZeusPeekBubble.prefix(full, count: 99).characters) == "Hi there")
    #expect(String(ZeusPeekBubble.prefix(full, count: -3).characters).isEmpty)
}

@Test func dialogTailEdgesMapToPaddingAndAlignment() {
    #expect(ZeusDialogModifier.paddingEdge(.leading) == .leading)
    #expect(ZeusDialogModifier.paddingEdge(.trailing) == .trailing)
    #expect(ZeusDialogModifier.paddingEdge(.top) == .top)
    #expect(ZeusDialogModifier.paddingEdge(nil) == .bottom)
    #expect(ZeusPeekBubble.tailPadding(ZeusDialogTail(edge: .leading, offset: 20)).leading == ZeusDialogTail.height)
    #expect(ZeusPeekBubble.tailPadding(nil) == EdgeInsets())
}

@MainActor @Test func peekBubbleRendersEveryVariant() throws {
    ZeusFonts.registerBundled()
    let options = [CardOption(id: "a", label: "Yes", style: .primary), CardOption(id: "b", label: "No", style: .secondary)]
    for edge in [ZeusDialogTail.Edge.top, .bottom, .leading, .trailing] {
        let view = ZeusPeekBubble(title: "Talk tomorrow", body: "Have you started on it?", options: options, acceptsText: true,
                                  moreCount: 2, highPriority: true, tail: ZeusDialogTail(edge: edge, offset: 30),
                                  reveal: .fraction(0.5), onOpen: {}, onClose: {})
        let image = try #require(ImageRenderer(content: view).cgImage)
        #expect(image.width >= Int(ZeusPeekTiming.minWidth) && image.width <= Int(ZeusPeekTiming.maxWidth + ZeusDialogTail.height) + 8)
    }
}

@Test func typewriterScheduleHasOneDatePerCharacterAndEnds() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let total = 80
    let dates = ZeusPeekTiming.revealDates(start: start, total: total)
    #expect(dates.count == total)
    #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
    for (k, date) in dates.enumerated() {
        #expect(ZeusPeekTiming.revealedCount(elapsed: date.timeIntervalSince(start), total: total) == k + 1)
    }
    let end = dates.last!.timeIntervalSince(start)
    #expect(abs(end - ZeusPeekTiming.typingDuration(length: total)) < 0.01)   // nothing scheduled after typing ends
    #expect(ZeusPeekTiming.revealDates(start: start, total: 0).isEmpty)
}

@Test func activityDotsCycle() {
    let base = Date(timeIntervalSinceReferenceDate: 0)
    let lit = (0..<8).map { ZeusActivityRow.litDots(at: base.addingTimeInterval(Double($0) * 0.3 + 0.01)) }
    #expect(lit == [0, 1, 2, 3, 0, 1, 2, 3])
}

@Test func markdownIsCachedPerPalette() {
    let md = "Cache **me** \(UUID().uuidString)"
    let a = ZeusMarkdown.attributed(md, choice: .pixel, palette: .dark)
    #expect(ZeusMarkdown.cache.withLock { $0.contains(.init(markdown: md, choice: .pixel, palette: .dark)) })
    #expect(ZeusMarkdown.attributed(md, choice: .pixel, palette: .dark) == a)
    var custom = ZeusPalette.dark
    custom.title = .red
    let c = ZeusMarkdown.attributed(md, choice: .pixel, palette: custom)       // its own entry, its own colors
    #expect(String(c.characters) == String(a.characters))
    #expect(c != a)
    #expect(ZeusMarkdown.cache.withLock { $0.contains(.init(markdown: md, choice: .pixel, palette: custom)) })
    for i in 0..<(ZeusMarkdown.cacheCapacity * 3) { _ = ZeusMarkdown.attributed("x\(i)", choice: .system, palette: .light) }
    #expect(ZeusMarkdown.cache.withLock { $0.count } <= ZeusMarkdown.cacheCapacity * 2)
}

/// S2: every palette `\.zeusPalette` produces (scheme × Increase Contrast) is a cache hit on the next body
/// evaluation, for both font choices, so scrolling a thread doesn't re-parse its messages.
@Test func environmentPalettesHitTheMarkdownCache() {
    var env = EnvironmentValues()
    for scheme in [ColorScheme.light, .dark] {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            env.colorScheme = scheme
            env._colorSchemeContrast = contrast
            for choice in ZeusFontChoice.allCases {
                let md = "Scroll **past** \(UUID().uuidString)"
                let first = ZeusMarkdown.attributed(md, choice: choice, palette: env.zeusPalette)
                // A fresh read of the environment, as a re-evaluated body does.
                var again = EnvironmentValues()
                again.colorScheme = scheme
                again._colorSchemeContrast = contrast
                let key = ZeusMarkdown.CacheKey(markdown: md, choice: choice, palette: again.zeusPalette)
                #expect(ZeusMarkdown.cache.withLock { $0.contains(key) }, "\(scheme) \(contrast) \(choice)")
                if case .custom = key.palette { Issue.record("\(scheme) \(contrast) hashes its colors on every lookup") }
                #expect(ZeusMarkdown.attributed(md, choice: choice, palette: again.zeusPalette) == first)
            }
        }
    }
}

/// S2: filling the cache keeps the entries still in use (the messages on screen) instead of dropping them all.
@Test func markdownCacheKeepsEntriesInUseWhenItFills() {
    var cache = ZeusMarkdown.Cache()
    func key(_ i: Int) -> ZeusMarkdown.CacheKey { .init(markdown: "m\(i)", choice: .pixel, palette: .dark) }
    let onScreen = key(-1)
    cache.insert(AttributedString("on screen"), for: onScreen)
    for i in 0..<(ZeusMarkdown.cacheCapacity * 4) {
        cache.insert(AttributedString("\(i)"), for: key(i))
        if i % 64 == 0 { #expect(cache.value(for: onScreen) != nil, "lost at \(i)") }
    }
    #expect(cache.value(for: onScreen) == AttributedString("on screen"))
    #expect(cache.value(for: key(0)) == nil)                                     // long unused: evicted
    #expect(cache.count <= ZeusMarkdown.cacheCapacity * 2)
}

@MainActor @Test func inactiveSurfacesDrawStaticFrames() async throws {
    ZeusFonts.registerBundled()
    func snapshot<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view.environment(\.zeusAnimationsActive, false).frame(width: 240))
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data as Data?)
    }
    let row = ZeusActivityRow("Working…", progress: 0.4)
    let bar = ZeusProgressBar(value: nil)
    let first = (try snapshot(row), try snapshot(bar))
    try await Task.sleep(for: .milliseconds(350))
    #expect(try snapshot(row) == first.0)
    #expect(try snapshot(bar) == first.1)
}

/// A4N-5: VoiceOver hears the bubble's words, not its markdown source.
@Test func peekAccessibilityLabelIsReadableText() {
    let body = "# Ready\n**Report** [open](https://example.invalid/report)\n> summary\n- first\n\n`make test` passed"
    let label = ZeusPeekBubble.accessibilityText(title: "Build", message: body)
    #expect(label == "Zeus says: Build. Ready. Report open. summary. first. make test passed")
    for syntax in ["#", "**", "](", "https://", ">", "`", "- first", "▌", "•"] { #expect(!label.contains(syntax), "\(syntax)") }
    #expect(ZeusPeekBubble.accessibilityText(title: nil, message: "Tests pass on **main**.") == "Zeus says: Tests pass on main.")
}
