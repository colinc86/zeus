#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import ZeusDesign

// D5 bug: "the placeholder text doesn't line up with the cursor".
// Root cause (measured): A3's composer drew its own placeholder `Text` over a `TextEditor` with a guessed
// `.padding(.top, 6)`. NSTextView lays text out with a 5 pt line-fragment padding and no top inset, so the
// overlay sat 5 pt left of and 6 pt below/above the caret, for both fonts. `ZeusComposer` uses the text
// field's own prompt, so the placeholder and the typed text share one layout.
//
// Proof: render the field with the placeholder showing, then with the same string typed in, and compare
// the bounding boxes of the glyph pixels. Real AppKit rendering (NSHostingView.cacheDisplay), because
// ImageRenderer can't draw text fields.

private let sample = "Message Zeus…"

@MainActor
private func snapshot<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// Bounding box (in pixels) of where `a` differs from `b`, limited to the left `maxX` points.
private func diffBox(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, maxX: CGFloat) -> CGRect? {
    let scale = CGFloat(a.pixelsWide) / a.size.width
    let limit = min(a.pixelsWide, Int(maxX * scale))
    var minX = Int.max, minY = Int.max, maxXp = -1, maxY = -1
    for y in 0..<a.pixelsHigh {
        for x in 0..<limit {
            guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
            let d = abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent)
            if d > 0.15 { minX = min(minX, x); maxXp = max(maxXp, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxXp >= 0 else { return nil }
    return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                  width: CGFloat(maxXp - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

private struct ComposerHarness: View {
    @State var text: String
    let placeholder: String
    let font: ZeusFontChoice
    @FocusState private var focused: Bool

    var body: some View {
        ZeusComposer(text: $text, placeholder: placeholder, focus: $focused, onClearReply: {}, onSend: {})
            .environment(\.zeusFontChoice, font)
            .frame(width: 340).padding(8)
            .frame(width: 360, height: 90, alignment: .topLeading)
            .background(ZeusPalette.dark.panel)
    }
}

private struct SingleLineHarness: View {
    @State var text: String
    let placeholder: String
    let font: ZeusFontChoice

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(ZeusTextFieldStyle())
            .environment(\.zeusFontChoice, font)
            .frame(width: 340).padding(8)
            .frame(width: 360, height: 60, alignment: .topLeading)
            .background(ZeusPalette.dark.panel)
    }
}

/// Placeholder glyphs vs. typed glyphs for one field configuration.
@MainActor
private func boxes(_ make: (_ text: String, _ placeholder: String) -> AnyView, size: CGSize) -> (placeholder: CGRect?, typed: CGRect?) {
    let blank = snapshot(make("", ""), size: size)
    let withPlaceholder = snapshot(make("", sample), size: size)
    let typed = snapshot(make(sample, ""), size: size)
    // Exclude the send button on the right: it enables when text is typed.
    return (diffBox(withPlaceholder, blank, maxX: 260), diffBox(typed, blank, maxX: 260))
}

@MainActor
@Test(arguments: ZeusFontChoice.allCases)
func composerPlaceholderLinesUpWithTypedText(font: ZeusFontChoice) throws {
    ZeusFonts.registerBundled()
    let (placeholder, typed) = boxes({ text, placeholder in
        AnyView(ComposerHarness(text: text, placeholder: placeholder, font: font))
    }, size: CGSize(width: 360, height: 90))
    let p = try #require(placeholder, "placeholder didn't render")
    let t = try #require(typed, "typed text didn't render")
    // Same string, same font, same origin: within one pixel at any backing scale.
    #expect(abs(p.minX - t.minX) <= 1, "x: placeholder \(p.minX) vs text \(t.minX)")
    #expect(abs(p.minY - t.minY) <= 1, "y: placeholder \(p.minY) vs text \(t.minY)")
    #expect(abs(p.height - t.height) <= 1)
}

@MainActor
@Test(arguments: ZeusFontChoice.allCases)
func singleLineFieldPlaceholderLinesUpWithTypedText(font: ZeusFontChoice) throws {
    ZeusFonts.registerBundled()
    let (placeholder, typed) = boxes({ text, placeholder in
        AnyView(SingleLineHarness(text: text, placeholder: placeholder, font: font))
    }, size: CGSize(width: 360, height: 60))
    let p = try #require(placeholder)
    let t = try #require(typed)
    #expect(abs(p.minX - t.minX) <= 1, "x: placeholder \(p.minX) vs text \(t.minX)")
    #expect(abs(p.minY - t.minY) <= 1, "y: placeholder \(p.minY) vs text \(t.minY)")
}

// MARK: - Keys

@MainActor
private final class KeyProbe {
    var text = ""
    var sends = 0
    var clears = 0
}

private struct KeyHarness: View {
    let probe: KeyProbe
    @State private var text = ""
    @State private var replying: String? = "Talk tomorrow"
    @FocusState private var focused: Bool

    var body: some View {
        ZeusComposer(text: $text, placeholder: "Message Zeus…", replyingTo: replying, focus: $focused,
                     onClearReply: { replying = nil; probe.clears += 1 },
                     onSend: { probe.sends += 1 })
            .frame(width: 340).padding(8)
            .onChange(of: text) { probe.text = text }
            .onAppear { focused = true }
    }
}

@MainActor
@Test func composerKeysSendNewlineAndClearChip() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let probe = KeyProbe()
    let host = NSHostingView(rootView: KeyHarness(probe: probe))
    host.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
    let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    app.activate()
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    func editor(_ v: NSView) -> NSView? {
        if v is NSTextField || v is NSTextView { return v }
        return v.subviews.lazy.compactMap(editor).first
    }
    if let field = editor(host) { window.makeFirstResponder(field) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            if let event { window.sendEvent(event) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }
    try #require(window.firstResponder is NSText || window.firstResponder is NSTextField, "the composer field must take focus")

    key("\u{7F}", 51)                      // Backspace in an empty field clears the chip
    #expect(probe.clears == 1)
    key("h", 4); key("i", 34)
    key("\r", 36, .shift)                  // ⇧Return: new line, no send
    key("x", 7)
    #expect(probe.text == "hi\nx")
    #expect(probe.sends == 0)
    key("\r", 36)                          // Return: send
    #expect(probe.sends == 1)
    key("\u{7F}", 51)                      // Backspace with text: just deletes
    #expect(probe.text == "hi\n")
    #expect(probe.clears == 1)
}

// MARK: - Restored draft (Q2 DES-1)

// A draft survives closing the panel. AppKit selects a text field's whole string when it becomes first
// responder, so the next keystroke replaced the draft. The composer puts the caret at the end instead.
// Focus goes through `makeFirstResponder`, the native path that does the select-all.

private struct DraftHarness: View {
    @State var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ZeusComposer(text: $text, placeholder: "Message Zeus…", focus: $focused, onClearReply: {}, onSend: {})
            .frame(width: 340).padding(8)
    }
}

@MainActor
@Test func restoredDraftGetsTheCaretAtTheEndNotASelection() throws {
    let draft = "Can you also check the expiry tests?"
    let length = (draft as NSString).length
    let host = NSHostingView(rootView: DraftHarness(text: draft))
    host.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
    let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func field(_ v: NSView) -> NSView? {
        if v is NSTextField || v is NSTextView { return v }
        return v.subviews.lazy.compactMap(field).first
    }
    let composer = try #require(field(host))
    func focus() throws -> NSRange {
        window.makeFirstResponder(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.makeFirstResponder(composer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let editor = try #require(window.firstResponder as? NSTextView, "the composer field must take focus")
        #expect(editor.string == draft, "focusing must not change the draft")
        return editor.selectedRange()
    }
    // The panel opens with a saved draft.
    let end = NSRange(location: length, length: 0)
    let opened = try focus()
    #expect(opened == end, "selected \(NSStringFromRange(opened))")
    // It opens again with the caret moved, and again with the caret already at the end (no state change).
    (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 3, length: 0))
    let reopened = try focus()
    #expect(reopened == end, "selected \(NSStringFromRange(reopened))")
    let again = try focus()
    #expect(again == end, "selected \(NSStringFromRange(again))")
}
/// Q2 DES-1: only AppKit's focus select-all moves the caret; a caret or selection the user placed stays.
@Test func onlyTheFocusSelectAllMovesTheCaret() {
    let text = "Draft to keep"
    let mid = text.index(text.startIndex, offsetBy: 5)
    #expect(ZeusComposer.selectsAll(nil, of: text))
    #expect(ZeusComposer.selectsAll(TextSelection(range: text.startIndex..<text.endIndex), of: text))
    #expect(!ZeusComposer.selectsAll(TextSelection(insertionPoint: mid), of: text))
    #expect(!ZeusComposer.selectsAll(TextSelection(range: text.startIndex..<mid), of: text))
    #expect(!ZeusComposer.selectsAll(TextSelection(insertionPoint: text.endIndex), of: text))
}
#endif

@Test func newlineInsertionRespectsTheCaret() {
    let text = "hello world"
    let mid = text.index(text.startIndex, offsetBy: 5)
    let (a, caretA) = ZeusComposer.insertingNewline(into: text, at: mid..<mid)
    #expect(a == "hello\n world")
    #expect(a.distance(from: a.startIndex, to: caretA) == 6)
    let end = text.index(text.startIndex, offsetBy: 11)
    let sel = text.index(text.startIndex, offsetBy: 6)
    let (b, _) = ZeusComposer.insertingNewline(into: text, at: sel..<end)   // replaces a selection
    #expect(b == "hello \n")
    let (c, _) = ZeusComposer.insertingNewline(into: "", at: nil)
    #expect(c == "\n")
}

@Test func composerSendRules() {
    #expect(!ZeusComposer.canSend("", isSending: false))
    #expect(!ZeusComposer.canSend("  \n ", isSending: false))
    #expect(ZeusComposer.canSend("hi", isSending: false))
    #expect(!ZeusComposer.canSend("hi", isSending: true))
}

@Test func conversationHelpers() {
    #expect(ZeusOptionButtons.shortcutLabel(index: 0) == "⌘1")
    #expect(ZeusOptionButtons.shortcutLabel(index: 8) == "⌘9")
    #expect(ZeusOptionButtons.shortcutLabel(index: 9) == nil)
    #expect(ZeusJumpPill.title(.latest(newCount: 3)) == "↓ 3 new")
    #expect(ZeusJumpPill.title(.latest(newCount: 0)) == "↓ Latest")
    let a = ZeusSessionLabel.colorIndex(for: "claude:/Users/me/Zeus")
    #expect(a == ZeusSessionLabel.colorIndex(for: "claude:/Users/me/Zeus"))
    #expect((0..<4).contains(a))
    #expect(Set(["claude:/a", "claude:/b", "codex:/a", "opencode:/c", "claude:/d"].map { ZeusSessionLabel.colorIndex(for: $0) }).count > 1)
}

