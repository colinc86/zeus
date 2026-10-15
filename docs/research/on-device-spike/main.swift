// LM2-D model spike. Synthetic data only: no real screen, no real names, nothing from the user's home.
import AppKit
import CoreImage
import Foundation
import FoundationModels
import NaturalLanguage
import Vision

// MARK: - Schemas proposed for platform

@Generable(description: "Private details found in a piece of text")
struct SensitiveSpans {
    @Guide(description: "Each private detail, copied exactly as it appears in the text. Empty if there are none.", .maximumCount(40))
    var spans: [SensitiveSpan]
}

@Generable
struct SensitiveSpan {
    @Guide(description: "The exact characters from the text, unchanged")
    var text: String
    var kind: SensitiveKind
}

@Generable
enum SensitiveKind {
    /// A private person's name (not a company, product, app or public figure).
    case personName
    /// Health, illness, medication, therapy or a medical appointment.
    case health
    /// Money owed, salary, balances, account details, debts.
    case finance
    /// A password, passcode, PIN, recovery phrase or secret described in words.
    case credential
    /// A street address or precise home location.
    case address
}

@Generable
struct SentenceFlags {
    @Guide(description: "Mentions someone's health, illness, medication, therapy or a medical appointment")
    var health: Bool
    @Guide(description: "Mentions personal money: salary, debts, balances, card or account details")
    var finance: Bool
    @Guide(description: "Gives a password, PIN or passphrase in words")
    var secret: Bool
}

@Generable(description: "A short, factual description of a screenshot of one Mac window")
struct ScreenDescription {
    @Guide(description: "The app in front, by name")
    var app: String
    @Guide(description: "The document, file, page or conversation title shown, or empty")
    var document: String
    @Guide(description: "One sentence, at most 25 words, saying what the person is doing. No names of private people, no numbers from the screen.")
    var summary: String
    var activity: ScreenActivity
    @Guide(description: "Up to three topic words", .maximumCount(3))
    var topics: [String]
    @Guide(description: "True if the screen shows private messages, health, banking, or a password")
    var looksPrivate: Bool
}

@Generable
enum ScreenActivity { case coding, writing, reading, chatting, meeting, designing, browsing, email, other }

// MARK: - Fixtures

let text200 = """
Hi team, quick notes from Thursday. Marta Kowalczyk said the release slips to next week because the signing \
certificate expired; Jonas Pereira will renew it. My password for the staging box is still tulip-river-42, so please \
change it after the demo. I have a dentist appointment on Friday at 10 and my physio said the knee needs two more weeks, \
so I'll work from home at 18 Alder Lane, Brookfield. Reach me at marta.k@example.com or +1 555 0134 if anything breaks. \
The invoice for the design agency came in at 4,200 euros; finance wants it paid from the card ending 4242 before the \
quarter closes, and my own salary review is on the 3rd. Priya Raman owns the onboarding copy now and wants feedback on \
the welcome card before Monday. Use the token sk-test-9f8e7d6c5b4a39281706 only in the sandbox. Also, the Zeus status \
strip should say waiting for your answer instead of pending. Oskar from Northwind Traders asked whether the MCP bridge \
works with Codex yet; I said next release. Lunch Wednesday at Café Lumen with Priya and Jonas to plan the roadmap, \
and someone remind Marta about her prescription refill. That's all, thanks everyone.
"""

/// A fake 1280×800 window: an editor, a failing test in a terminal, and a sidebar. Drawn, never captured.
func syntheticScreenshot() -> CGImage {
    let size = NSSize(width: 1280, height: 800)
    let image = NSImage(size: size, flipped: true) { rect in
        NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
        NSColor(white: 0.18, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1280, height: 28).fill()
        NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: 0, y: 28, width: 220, height: 772).fill()
        NSColor(white: 0.08, alpha: 1).setFill(); NSRect(x: 220, y: 560, width: 1060, height: 240).fill()
        func draw(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 13, _ color: NSColor = .white) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: color])
        }
        draw("Xcode — ManagedSessionController.swift", 480, 6, 13, .lightGray)
        for (i, f) in ["ShellController.swift", "ManagedSessionController.swift", "ZeusMenuModel.swift", "GlobalHotKey.swift", "Tests"].enumerated() {
            draw(f, 16, 44 + CGFloat(i) * 22, 12, i == 1 ? .white : .gray)
        }
        let code = ["final class ManagedSessionController {", "    func restart(keepingConversation: Bool) async throws {",
                    "        guard state == .idle else { throw RestartError.busy }", "        try await tmux.respawn(pane: pane)",
                    "        if keepingConversation { try await resume(lastSession) }", "    }", "}"]
        for (i, line) in code.enumerated() { draw(line, 240, 48 + CGFloat(i) * 20, 13, .init(red: 0.8, green: 0.85, blue: 1, alpha: 1)) }
        draw("$ scripts/test.sh", 236, 572, 12, .lightGray)
        draw("✘ Test restartKeepsConversation() failed: expected resumed session, got nil", 236, 594, 12, .systemRed)
        draw("Executed 812 tests, with 1 failure", 236, 616, 12, .lightGray)
        return true
    }
    var r = NSRect(origin: .zero, size: size)
    return image.cgImage(forProposedRect: &r, context: nil, hints: nil)!
}

// MARK: - Timing

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
func time(_ label: String, runs: Int, _ body: () async throws -> String) async {
    var times: [Double] = []; var last = ""
    for i in 0..<runs {
        let clock = ContinuousClock(); let start = clock.now
        do { last = try await body() } catch { print("  \(label) run \(i): ERROR \(error)"); return }
        times.append(ms(clock.now - start))
    }
    print(String(format: "  %@: first %.0f ms, median %.0f ms, min %.0f, max %.0f (n=%d)", label, times[0], median(times), times.min()!, times.max()!, runs))
    print("    → " + last.replacingOccurrences(of: "\n", with: " ").prefix(600))
}

// MARK: - Main

let wordCount = text200.split(whereSeparator: \.isWhitespace).count
print("Text fixture: \(wordCount) words")
let runs = Int(CommandLine.arguments.dropFirst().first ?? "5") ?? 5

print("\n== SystemLanguageModel (on-device)")
let system = SystemLanguageModel.default
print("  availability: \(system.availability)")
print("  variant: \(system.variant.displayName)  contextSize: \(system.contextSize)")
let caps = system.capabilities
print("  capabilities: vision=\(caps.contains(.vision)) guided=\(caps.contains(.guidedGeneration)) reasoning=\(caps.contains(.reasoning)) tools=\(caps.contains(.toolCalling))")
print("  supports current locale: \(system.supportsLocale())")
let redactInstructions = "You find private details in text so they can be removed before the text is stored. Report only details in the five kinds. Never report company, product, app or place-of-business names."

if system.isAvailable {
    if let n = try? await system.tokenCount(for: Prompt(text200)) { print("  tokens in 200-word fixture: \(n)") }
    if let n = try? await system.tokenCount(for: SensitiveSpans.generationSchema) { print("  tokens for SensitiveSpans schema: \(n)") }
    if let n = try? await system.tokenCount(for: ScreenDescription.generationSchema) { print("  tokens for ScreenDescription schema: \(n)") }
    let session0 = LanguageModelSession(model: system, instructions: redactInstructions)
    session0.prewarm()
    await time("redaction spans, 200 words, fresh session each run", runs: runs) {
        let session = LanguageModelSession(model: system, instructions: redactInstructions)
        let r = try await session.respond(to: text200, generating: SensitiveSpans.self, options: GenerationOptions(samplingMode: .greedy))
        return r.content.spans.map { "\($0.kind):\($0.text)" }.joined(separator: " | ")
    }
    // Variant B: stage 1 + NLTagger first, then the model only for prose kinds, one sentence at a time.
    let preRedacted = text200
        .replacingOccurrences(of: "marta.k@example.com", with: "‹email›").replacingOccurrences(of: "+1 555 0134", with: "‹phone›")
        .replacingOccurrences(of: "sk-test-9f8e7d6c5b4a39281706", with: "‹secret›").replacingOccurrences(of: "18 Alder Lane, Brookfield", with: "‹address›")
        .replacingOccurrences(of: "Marta Kowalczyk", with: "‹name›").replacingOccurrences(of: "Jonas Pereira", with: "‹name›")
        .replacingOccurrences(of: "Priya Raman", with: "‹name›").replacingOccurrences(of: "Marta", with: "‹name›")
        .replacingOccurrences(of: "Priya", with: "‹name›").replacingOccurrences(of: "Jonas", with: "‹name›").replacingOccurrences(of: "Oskar", with: "‹name›")
    let proseInstructions = "Text arrives with some details already replaced by ‹…› placeholders. Find what is still private: health (illness, medication, therapy, medical appointments), personal finances (amounts, salary, debts, card or account hints), and secrets written in words (a password or PIN given in prose). Copy each exactly. Ignore placeholders. Ignore work topics, products and companies."
    await time("variant B: prose kinds on pre-redacted text, whole text", runs: runs) {
        let session = LanguageModelSession(model: system, instructions: proseInstructions)
        let r = try await session.respond(to: preRedacted, generating: SensitiveSpans.self, options: GenerationOptions(samplingMode: .greedy))
        return r.content.spans.map { "\($0.kind):\($0.text)" }.joined(separator: " | ")
    }
    let permissive = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    await time("variant B2: permissive guardrails", runs: runs) {
        let session = LanguageModelSession(model: permissive, instructions: proseInstructions)
        let r = try await session.respond(to: preRedacted, generating: SensitiveSpans.self, options: GenerationOptions(samplingMode: .greedy))
        return r.content.spans.map { "\($0.kind):\($0.text)" }.joined(separator: " | ")
    }
    await time("variant C: boolean flags per sentence (13 sentences, sequential)", runs: 2) {
        var hits: [String] = []
        for sentence in preRedacted.split(separator: ".") where sentence.count > 3 {
            let session = LanguageModelSession(model: permissive, instructions: proseInstructions)
            let r = try await session.respond(to: String(sentence), generating: SentenceFlags.self, options: GenerationOptions(samplingMode: .greedy))
            if r.content.health || r.content.finance || r.content.secret { hits.append("[\(r.content.health ? "H" : "")\(r.content.finance ? "F" : "")\(r.content.secret ? "S" : "")]\(sentence.prefix(40))") }
        }
        return hits.joined(separator: " | ")
    }
    let tagging = SystemLanguageModel(useCase: .contentTagging)
    await time("redaction spans, contentTagging use case", runs: runs) {
        let session = LanguageModelSession(model: tagging, instructions: redactInstructions)
        let r = try await session.respond(to: text200, generating: SensitiveSpans.self, options: GenerationOptions(samplingMode: .greedy))
        return r.content.spans.map { "\($0.kind):\($0.text)" }.joined(separator: " | ")
    }
    let shot = syntheticScreenshot()
    if caps.contains(.vision) {
        await time("screenshot description 1280×800 (image in)", runs: runs) {
            let session = LanguageModelSession(model: system, instructions: "Describe the screenshot for a private activity journal.")
            let r = try await session.respond(generating: ScreenDescription.self, options: GenerationOptions(samplingMode: .greedy)) {
                "Describe this window."
                Attachment(shot)
            }
            return "\(r.content)"
        }
    } else { print("  on-device model has no vision capability") }
} else { print("  skipped generation: not available") }

print("\n== PrivateCloudComputeLanguageModel")
let pcc = PrivateCloudComputeLanguageModel()
print("  availability: \(pcc.availability)")
let pcaps = pcc.capabilities
print("  capabilities: vision=\(pcaps.contains(.vision)) guided=\(pcaps.contains(.guidedGeneration)) reasoning=\(pcaps.contains(.reasoning)) tools=\(pcaps.contains(.toolCalling))")
print("  quota: limitReached=\(pcc.quotaUsage.isLimitReached) reset=\(String(describing: pcc.quotaUsage.resetDate))")
if let c = try? await pcc.contextSize { print("  contextSize: \(c)") }
if pcc.isAvailable && CommandLine.arguments.contains("--pcc") {
    await time("PCC redaction spans, 200 words", runs: 3) {
        let session = LanguageModelSession(model: pcc, instructions: redactInstructions)
        let r = try await session.respond(to: text200, generating: SensitiveSpans.self)
        return r.content.spans.map { "\($0.kind):\($0.text)" }.joined(separator: " | ")
    }
    let shot = syntheticScreenshot()
    await time("PCC screenshot description", runs: 3) {
        let session = LanguageModelSession(model: pcc, instructions: "Describe the screenshot for a private activity journal.")
        let r = try await session.respond(generating: ScreenDescription.self) { "Describe this window."; Attachment(shot) }
        return "\(r.content)"
    }
}

print("\n== NaturalLanguage NLTagger (.nameType)")
await time("names/places/orgs, 200 words", runs: runs) {
    let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text200
    var found: [String] = []
    tagger.enumerateTags(in: text200.startIndex..<text200.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
        if let tag, [.personalName, .placeName, .organizationName].contains(tag) { found.append("\(tag.rawValue):\(text200[range])") }
        return true
    }
    return found.joined(separator: " | ")
}

print("\n== NSDataDetector")
await time("emails, phones, addresses, links", runs: runs) {
    let d = try NSDataDetector(types: NSTextCheckingResult.CheckingType([.phoneNumber, .address, .link]).rawValue)
    return d.matches(in: text200, range: NSRange(text200.startIndex..., in: text200)).map { (text200 as NSString).substring(with: $0.range) }.joined(separator: " | ")
}

print("\n== Vision on the synthetic 1280×800 screenshot")
let shot = syntheticScreenshot()
await time("RecognizeTextRequest .accurate", runs: runs) {
    var req = RecognizeTextRequest(); req.recognitionLevel = .accurate
    let obs = try await req.perform(on: shot)
    return "\(obs.count) lines: " + obs.prefix(4).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " / ")
}
await time("RecognizeTextRequest .fast", runs: runs) {
    var req = RecognizeTextRequest(); req.recognitionLevel = .fast
    let obs = try await req.perform(on: shot)
    return "\(obs.count) lines"
}
await time("DetectFaceRectanglesRequest", runs: runs) {
    let obs = try await DetectFaceRectanglesRequest().perform(on: shot); return "\(obs.count) faces"
}
await time("DetectHumanRectanglesRequest", runs: runs) {
    let obs = try await DetectHumanRectanglesRequest().perform(on: shot); return "\(obs.count) humans"
}
await time("perceptual hash (FeaturePrint)", runs: runs) {
    let obs = try await GenerateImageFeaturePrintRequest().perform(on: shot); return "\(obs.elementCount) floats"
}
