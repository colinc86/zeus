// LM2-D3 keystroke spike (Phase C, "hands"). Isolation rules, enforced in code:
// - The only tap whose callback runs is a per-process tap on THIS process (CGEventTapCreateForPid(getpid())).
// - Its callback reads one field first, eventSourceUserData, and ignores (does not read) any event that lacks this
//   program's marker. Every marked event is synthetic and posted to this process only (postToPid), never system-wide.
// - The system-wide HID tap is only created, checked and removed, with no run loop in between, so its callback never runs.
// - The pasteboard test uses a private named pasteboard, never the general one. Run with a disposable HOME.
// Build: xcrun swiftc -O -swift-version 6 keys.swift -o keys && HOME=$(mktemp -d) ./keys
import AppKit
import Carbon
import CoreGraphics
import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Schema proposed for platform (LM2-D3 C)

@Generable(description: "What a person was doing in one stretch of typing, without the words they typed")
struct TypingTopic {
    @Guide(description: "The app they typed in, by name")
    var app: String
    var intent: TypingIntent
    @Guide(description: "What the typing was about, in at most 8 words. A topic, not a quote. No names of people, no numbers, no addresses, no secrets.")
    var subject: String
    @Guide(description: "Who it was for, as roles only (for example: colleague, manager, client, doctor, family member, support team). Never names. Empty if unclear.", .maximumCount(3))
    var recipients: [String]
}

@Generable struct RunSpans { @Guide(.maximumCount(12)) var spans: [RunSpan] }
@Generable struct RunSpan { var text: String; var kind: RunKind }
@Generable enum RunKind { case personName, health, finance, secret }

/// The current thread's run loop, outside async contexts.
func currentRunLoop() -> CFRunLoop { CFRunLoopGetCurrent() }

@Generable
enum TypingIntent { case replying, drafting, searching, coding, notes, commanding, filling, chatting, other }

// MARK: - Helpers

let marker: Int64 = 0x5A_4555_534B_45 // "ZEUSKE"
func ns() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

/// UCKeyTranslate for one key-down in a given layout, carrying dead-key state between keys.
struct Translator {
    let layout: UnsafePointer<UCKeyboardLayout>
    let data: CFData
    var deadKeys: UInt32 = 0
    init?(sourceID: String?) {
        let source: TISInputSource?
        if let sourceID {
            let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
            source = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        } else {
            source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    }
    mutating func text(keyCode: UInt16, flags: CGEventFlags) -> String {
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        var chars = [UniChar](repeating: 0, count: 4); var length = 0
        UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), 0, &deadKeys, 4, &length, &chars)
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - The per-process tap

final class TapState: @unchecked Sendable {
    var keys: [(code: UInt16, flags: CGEventFlags, t: UInt64, cost: UInt64)] = []
    var unmarked = 0
    var disabled: [String] = []
    var translator: Translator?
    var typed = ""
    var slowNext = false
    var sourceStates: Set<Int64> = []
}
let state = TapState()

let callback: CGEventTapCallBack = { _, type, event, refcon in
    let s = Unmanaged<TapState>.fromOpaque(refcon!).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        s.disabled.append(type == .tapDisabledByTimeout ? "timeout" : "userInput")
        return Unmanaged.passUnretained(event)
    }
    // Isolation: anything not posted by this program is passed through unread.
    guard event.getIntegerValueField(.eventSourceUserData) == marker else { s.unmarked += 1; return Unmanaged.passUnretained(event) }
    let start = ns()
    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    if type == .keyDown, !flags.contains(.maskCommand), !flags.contains(.maskControl) {
        s.typed += s.translator?.text(keyCode: code, flags: flags) ?? ""
    }
    s.keys.append((code, flags, start, ns() - start))
    s.sourceStates.insert(event.getIntegerValueField(.eventSourceStateID))
    if s.slowNext { s.slowNext = false; usleep(1_500_000) }
    return Unmanaged.passUnretained(event)
}

func post(_ code: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.postToPid(getpid())
    }
}
func pump(_ seconds: Double = 0.05) { CFRunLoopRunInMode(.defaultMode, seconds, false) }

// MARK: - Main

let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
print("HOME = \(home.hasPrefix("/Users/") ? "real home (re-run with a disposable HOME)" : "disposable")")
// A per-process tap needs this process to have a window-server connection first.
_ = NSApplication.shared
print("Input Monitoring preflight (no prompt): listen=\(CGPreflightListenEventAccess())")

print("\n== System-wide HID tap: create, check, remove (callback never runs)")
do {
    let t0 = ns()
    let hid = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
    let created = ns() - t0
    if let hid {
        print(String(format: "  created in %.2f ms, enabled=%@", Double(created) / 1e6, CGEvent.tapIsEnabled(tap: hid) ? "yes" : "no"))
        CGEvent.tapEnable(tap: hid, enable: false); CFMachPortInvalidate(hid)
    } else {
        print("  tapCreate returned nil: Input Monitoring is not granted to this process")
    }
}

print("\n== Per-process tap + UCKeyTranslate")
guard let tap = CGEvent.tapCreateForPid(pid: getpid(), place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                         callback: callback, userInfo: Unmanaged.passUnretained(state).toOpaque()) else {
    print("  tapCreateForPid returned nil"); exit(1)
}
let loopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(currentRunLoop(), loopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
let source = CGEventSource(stateID: .privateState)!

// US letters, a capital, and the option-e dead key followed by e (é) in the US layout.
let cases: [(String, String, [(CGKeyCode, CGEventFlags)])] = [
    ("com.apple.keylayout.US", "hello É é", [(4, []), (14, []), (37, []), (37, []), (31, []), (49, []), (14, .maskAlternate), (14, .maskShift), (49, []), (14, .maskAlternate), (14, [])]),
    ("com.apple.keylayout.German", "zy ä", [(16, []), (6, []), (49, []), (39, [])]),
    ("com.apple.keylayout.French", "aq ê", [(12, []), (0, []), (49, []), (33, []), (14, [])]),
]
for (layoutID, expected, keys) in cases {
    guard let t = Translator(sourceID: layoutID) else { print("  \(layoutID): layout not available"); continue }
    state.translator = t; state.typed = ""; state.keys.removeAll()
    for (code, flags) in keys { post(code, flags: flags, source: source) }
    pump(0.3)
    let costs = state.keys.map { Double($0.cost) / 1000 }.sorted()
    print("  \(layoutID): typed \"\(state.typed)\" (expected \"\(expected)\") \(state.typed == expected ? "✓" : "✗"), \(state.keys.count) events, callback+translate median \(String(format: "%.1f", costs.isEmpty ? 0 : costs[costs.count / 2])) µs, max \(String(format: "%.1f", costs.last ?? 0)) µs")
}

// Throughput: 2,000 marked keys.
state.translator = Translator(sourceID: "com.apple.keylayout.US"); state.keys.removeAll(); state.typed = ""
let burst = ns()
for i in 0..<2000 { post(CGKeyCode([0, 11, 8, 2, 14, 3, 5][i % 7]), source: source); if i % 100 == 0 { pump(0.001) } }
pump(0.5)
let costs = state.keys.map { Double($0.cost) / 1000 }.sorted()
print(String(format: "  2,000 keys: %d seen, callback+translate median %.1f µs, p99 %.1f µs; wall %.0f ms incl. posting", state.keys.count,
             costs[costs.count / 2], costs[min(costs.count - 1, costs.count * 99 / 100)], Double(ns() - burst) / 1e6))
print("  unmarked events seen by the per-process tap (passed through unread): \(state.unmarked)")
print("  eventSourceStateID of synthetic keys: \(state.sourceStates.sorted()) (hardware keys carry \(CGEventSourceStateID.hidSystemState.rawValue), hidSystemState)")

print("\n== Tap disabled by a slow callback (listen-only)")
state.slowNext = true
post(4, source: source); pump(0.2); post(4, source: source); pump(2.5)
print("  disabled callbacks: \(state.disabled.isEmpty ? "none" : state.disabled.joined(separator: ", ")); tap enabled now: \(CGEvent.tapIsEnabled(tap: tap))")
if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }

print("\n== Secure input")
print("  before: IsSecureEventInputEnabled=\(IsSecureEventInputEnabled())")
var flips: [Double] = []
for _ in 0..<20 {
    let t0 = ns(); EnableSecureEventInput()
    while !IsSecureEventInputEnabled(), ns() - t0 < 50_000_000 {}
    flips.append(Double(ns() - t0) / 1000)
    DisableSecureEventInput()
}
flips.sort()
print(String(format: "  Enable → IsSecureEventInputEnabled true: median %.1f µs, max %.1f µs (n=20)", flips[10], flips[19]))
var checks: [Double] = []
for _ in 0..<1000 { let t0 = ns(); _ = IsSecureEventInputEnabled(); checks.append(Double(ns() - t0)) }
checks.sort()
print(String(format: "  IsSecureEventInputEnabled() cost: median %.0f ns, p99 %.0f ns", checks[500], checks[990]))
// Does a key reach the per-process tap while secure input is on?
EnableSecureEventInput(); state.keys.removeAll()
post(4, source: source); pump(0.2)
print("  marked key reached our tap while secure input was on: \(state.keys.isEmpty ? "no" : "yes")")
DisableSecureEventInput()
// An NSSecureTextField becoming first responder in a window of this (background) app.
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
window.contentView?.addSubview(secure); window.orderFrontRegardless()
let f0 = ns(); window.makeFirstResponder(secure)
var flipped: Double? = nil
while ns() - f0 < 200_000_000 { if IsSecureEventInputEnabled() { flipped = Double(ns() - f0) / 1000; break }; pump(0.001) }
print("  NSSecureTextField first responder in a non-active app: secure input " + (flipped.map { String(format: "on after %.0f µs", $0) } ?? "stayed off (AppKit enables it only for the active app's key window)"))
window.makeFirstResponder(nil); window.orderOut(nil)

print("\n== Typing runs (coalescing logic on a synthetic stream)")
struct Key { let t: Double; let app: String; let window: String; let text: String; let backspace: Bool; let paste: Bool }
struct Run { var app: String; var window: String; var start: Double; var end: Double; var text: String; var pastes: Int }
func coalesce(_ keys: [Key], gap: Double = 2) -> [Run] {
    var runs: [Run] = []
    for k in keys {
        if var last = runs.last, last.app == k.app, last.window == k.window, k.t - last.end <= gap {
            if k.backspace { if !last.text.isEmpty { last.text.removeLast() } }
            else if k.paste { last.text += "‹pasted›"; last.pastes += 1 }
            else { last.text += k.text }
            last.end = k.t; runs[runs.count - 1] = last
        } else if !k.backspace {
            runs.append(Run(app: k.app, window: k.window, start: k.t, end: k.t, text: k.paste ? "‹pasted›" : k.text, pastes: k.paste ? 1 : 0))
        }
    }
    return runs
}
var stream: [Key] = []
var t = 0.0
@MainActor func type(_ s: String, app: String, window: String, every: Double = 0.12) { for c in s { stream.append(Key(t: t, app: app, window: window, text: String(c), backspace: false, paste: false)); t += every } }
type("Hi Dr Osei, can we move Thursday to 4pm", app: "Mail", window: "Re: Appointment")
for _ in 0..<3 { stream.append(Key(t: t, app: "Mail", window: "Re: Appointment", text: "", backspace: true, paste: false)); t += 0.1 }
type("3pm? My knee is still sore.", app: "Mail", window: "Re: Appointment")
t += 3 // pause > 2 s ends the run
type("token: ", app: "Terminal", window: "zsh")
stream.append(Key(t: t, app: "Terminal", window: "zsh", text: "", backspace: false, paste: true)); t += 0.2
type(" curl api", app: "Terminal", window: "zsh")
t += 0.5
type("fix restart race", app: "Xcode", window: "ManagedSessionController.swift")
let runs = coalesce(stream)
for r in runs { print(String(format: "  [%@ · %@] %.1fs: \"%@\"%@", r.app, r.window, r.end - r.start, r.text, r.pastes > 0 ? " (\(r.pastes) paste)" : "")) }
let ct = ContinuousClock(); let c0 = ct.now
for _ in 0..<1000 { _ = coalesce(stream) }
print(String(format: "  coalescing cost: %.2f µs per key", ms(ct.now - c0) * 1000 / Double(1000 * stream.count)))

print("\n== Paste detection (private pasteboard, never the general one)")
let board = NSPasteboard(name: NSPasteboard.Name("zeus-lm2-spike-\(UUID().uuidString)"))
var lastCount = board.changeCount
board.clearContents(); board.setString("sk-live-NOT-A-REAL-KEY-0000", forType: .string)
let changed = board.changeCount != lastCount; lastCount = board.changeCount
let pc0 = ns(); for _ in 0..<1000 { _ = board.changeCount }; let pcCost = Double(ns() - pc0) / 1000
print(String(format: "  changeCount moved after a copy: %@; reading changeCount costs %.0f ns (content never read)", changed ? "yes" : "no", pcCost))
board.releaseGlobally()

print("\n== Redactor recall: typed runs vs the same words as prose")
// Typed runs are lower-case, unpunctuated and full of fragments; prose is the cleaned-up sentence.
let pairs: [(run: String, prose: String, planted: [String])] = [
    ("hi dr osei can we move thursday to 3pm my knee is still sore", "Hi Dr Osei, can we move Thursday to 3pm? My knee is still sore.", ["osei", "knee"]),
    ("send it to maria.lopez@example.com and cc jonas", "Send it to maria.lopez@example.com and cc Jonas.", ["maria.lopez@example.com", "jonas"]),
    ("call me on 555 0147 after 6", "Call me on 555 0147 after 6.", ["555 0147"]),
    ("my pin is 4471 dont share", "My PIN is 4471, don't share.", ["4471"]),
    ("card 4242 4242 4242 4242 exp 0428", "Card 4242 4242 4242 4242, exp 04/28.", ["4242 4242 4242 4242"]),
    ("thanks priya see you at 14 elm road", "Thanks Priya, see you at 14 Elm Road.", ["priya", "14 elm road"]),
    ("password is tulip river 42", "The password is tulip-river-42.", ["tulip river 42"]),
    ("loan repayment of 1200 is late again", "The loan repayment of 1,200 is late again.", ["1200"]),
]
func stage1(_ text: String) -> [String] {
    var hits: [String] = []
    let ns = text as NSString
    if let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType([.phoneNumber, .address, .link]).rawValue) {
        hits += d.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    let patterns = [#"[\w.+-]+@[\w-]+\.[\w.]+"#, #"\b(?:\d[ -]?){13,19}\b"#, #"(?i)\b(?:password|pwd|pin|passcode)\b(?:\s+is)?[:\s]+\S+(?:[\s-]\S+){0,2}"#]
    for p in patterns { if let r = try? NSRegularExpression(pattern: p) { hits += r.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } } }
    let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
        if tag == .personalName { hits.append(String(text[r])) }; return true
    }
    return hits
}
func recall(_ text: String, _ planted: [String], extra: [String] = []) -> Int {
    let found = (stage1(text) + extra).map { $0.lowercased() }.joined(separator: " | ")
    return planted.filter { p in found.contains(p.lowercased()) || found.contains(p.lowercased().replacingOccurrences(of: " ", with: "-")) }.count
}
let total = pairs.map(\.planted.count).reduce(0, +)
let runRecall = pairs.map { recall($0.run, $0.planted) }.reduce(0, +)
let proseRecall = pairs.map { recall($0.prose, $0.planted) }.reduce(0, +)
print("  stage 1 (patterns + NSDataDetector + NLTagger): runs \(runRecall)/\(total), prose \(proseRecall)/\(total)")

print("\n== On-device model: runs → topics, and stage 2 on runs")
let model = SystemLanguageModel.default
print("  availability: \(model.availability)")
if model.isAvailable {
    let topicInstructions = "You summarise what someone was doing while typing, for their private activity journal. Give a topic, never a quote. Never include names of people, numbers, addresses, health details or secrets; describe recipients only by their role."
    for (i, pair) in pairs.prefix(5).enumerated() {
        let app = ["Mail", "Mail", "Messages", "Notes", "Safari"][i]
        let c0 = ct.now
        do {
            let topic = try await LanguageModelSession(model: model, instructions: topicInstructions)
                .respond(to: "App: \(app)\nTyped: \(pair.run)", generating: TypingTopic.self, options: GenerationOptions(samplingMode: .greedy)).content
            print(String(format: "  %.0f ms · %@ → %@ · \"%@\" · %@", ms(ct.now - c0), app, "\(topic.intent)", topic.subject, topic.recipients.joined(separator: ", ")))
        } catch { print("  run \(i): ERROR \(error)") }
    }
    let proseInstructions = "Text arrives with some details already replaced by ‹…› placeholders. Find what is still private: names of private people, health (illness, medication, therapy, medical appointments), personal money (amounts, salary, debts, card or account hints), and secrets written in words (a password or PIN given in prose). Copy each exactly. Ignore placeholders. Ignore work topics, products, apps and companies."
    var modelRun = 0, modelProse = 0, times: [Double] = []
    for pair in pairs {
        for (text, isRun) in [(pair.run, true), (pair.prose, false)] {
            let c0 = ct.now
            let spans = (try? await LanguageModelSession(model: model, instructions: proseInstructions)
                .respond(to: text, generating: RunSpans.self, options: GenerationOptions(samplingMode: .greedy)).content.spans.map(\.text)) ?? []
            times.append(ms(ct.now - c0))
            let r = recall(text, pair.planted, extra: spans)
            if isRun { modelRun += r } else { modelProse += r }
        }
    }
    times.sort()
    print("  stage 1 + 2: runs \(modelRun)/\(total), prose \(modelProse)/\(total); stage 2 median \(String(format: "%.0f", times[times.count / 2])) ms per run")
}

CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap)
print("\ndone")
