// LM2-D2 Vision spike (Phase B, "eyes"). Synthetic frames only: every frame is drawn here, nothing is captured.
// Build: xcrun swiftc -O -swift-version 6 vision.swift -o vision && ./vision [runs] [--write DIR]
import AppKit
import Carbon
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMediaIO
import Foundation
import FoundationModels
import Vision

// MARK: - Schema proposed for platform (LM2-D2 C)

@Generable(description: "A short, factual description of one Mac window for a private activity journal")
struct FrameDescription {
    @Guide(description: "The app in front, by name, for example Xcode, Terminal or Safari")
    var app: String
    @Guide(description: "The document, file, web page or conversation the window shows, or empty if none is visible")
    var document: String
    @Guide(description: "One sentence of at most 20 words saying what the person is doing. No names of private people, no numbers, no addresses, no secrets.")
    var activity: String
    @Guide(description: "True if the window visibly shows a password, key, token, card or account number, private messages, health or banking details")
    var visibleSecrets: Bool
}

// MARK: - Synthetic frames

/// Optional face photos (`--faces DIR`, JPEGs), composited into the Safari frame as an advisor photo and a contact avatar.
nonisolated(unsafe) var facePhotos: [CGImage]? = nil

enum FrameKind: String, CaseIterable { case terminal, xcode, safari }

struct Frame { let kind: FrameKind; let scale: CGFloat; let image: CGImage; let app: String; let window: String
    var label: String { "\(kind.rawValue) \(Int(1280 * scale))×\(Int(800 * scale))" } }

/// Draws a fake window. `scroll` shifts the content up by that many points (for the dHash test); `clock` changes one
/// small label (for the "only the clock changed" test).
func draw(_ kind: FrameKind, scale: CGFloat, scroll: CGFloat = 0, clock: String = "09:41", faces: Bool = true) -> CGImage {
    let size = NSSize(width: 1280 * scale, height: 800 * scale)
    let image = NSImage(size: size, flipped: true) { _ in
        let s = scale
        func text(_ t: String, _ x: CGFloat, _ y: CGFloat, _ pt: CGFloat = 13, _ color: NSColor = .white, mono: Bool = true, bold: Bool = false) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: pt * s, weight: bold ? .bold : .regular) : NSFont.systemFont(ofSize: pt * s, weight: bold ? .semibold : .regular)
            (t as NSString).draw(at: NSPoint(x: x * s, y: (y - scroll) * s), withAttributes: [.font: font, .foregroundColor: color])
        }
        func rect(_ c: NSColor, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { c.setFill(); NSRect(x: x * s, y: y * s, width: w * s, height: h * s).fill() }
        switch kind {
        case .terminal:
            rect(NSColor(white: 0.1, alpha: 1), 0, 0, 1280, 800)
            rect(NSColor(white: 0.2, alpha: 1), 0, 0, 1280, 28)
            text("zeus — zsh — 160×48", 540, 6, 13, .lightGray, mono: false)
            let lines = ["$ git log --oneline -3", "4f2a9c1 Fix restart race (Dana Whitfield)", "9be01d7 Add journal viewer (Sam Okafor)",
                         "$ export API_TOKEN=sk-live-51Hx9QeL2mNvR8tYc3bW7dKz", "$ curl -H \"Authorization: Bearer $API_TOKEN\" https://api.example.com/v1/me",
                         "{\"email\": \"dana.whitfield@example.com\", \"plan\": \"team\"}", "$ scripts/test.sh",
                         "✘ Test restartKeepsConversation() failed: expected resumed session, got nil", "Executed 812 tests, with 1 failure", "$ "]
            for (i, l) in lines.enumerated() { text(l, 16, 44 + CGFloat(i) * 22, 14, i == 7 ? .systemRed : .init(white: 0.9, alpha: 1)) }
            text(clock, 1220, 6, 12, .lightGray, mono: false)
        case .xcode:
            rect(NSColor(white: 0.12, alpha: 1), 0, 0, 1280, 800)
            rect(NSColor(white: 0.18, alpha: 1), 0, 0, 1280, 28)
            rect(NSColor(white: 0.15, alpha: 1), 0, 28, 220, 772)
            rect(NSColor(white: 0.08, alpha: 1), 220, 560, 1060, 240)
            text("Xcode — ManagedSessionController.swift", 480, 6, 13, .lightGray, mono: false)
            for (i, f) in ["ShellController.swift", "ManagedSessionController.swift", "ZeusMenuModel.swift", "GlobalHotKey.swift", "Tests"].enumerated() {
                text(f, 16, 44 + CGFloat(i) * 22, 12, i == 1 ? .white : .gray, mono: false)
            }
            let code = ["final class ManagedSessionController {", "    let keychainService = \"Zeus Journal\"",
                        "    func restart(keepingConversation: Bool) async throws {", "        guard state == .idle else { throw RestartError.busy }",
                        "        try await tmux.respawn(pane: pane)", "        if keepingConversation { try await resume(lastSession) }", "    }", "}"]
            for (i, line) in code.enumerated() { text(line, 240, 48 + CGFloat(i) * 20, 13, .init(red: 0.8, green: 0.85, blue: 1, alpha: 1)) }
            text("✘ restartKeepsConversation(): expected resumed session, got nil", 236, 580, 12, .systemRed)
            text(clock, 1220, 6, 12, .lightGray, mono: false)
        case .safari:
            rect(NSColor(white: 0.97, alpha: 1), 0, 0, 1280, 800)
            rect(NSColor(white: 0.9, alpha: 1), 0, 0, 1280, 52)
            rect(.white, 360, 12, 560, 28)
            text("bank.example.com/accounts/checking", 380, 17, 13, .darkGray, mono: false)
            text("Northwind Bank — Checking", 60, 80, 26, .black, mono: false, bold: true)
            text("Account 4401 2233 9876 · Balance $12,480.17", 60, 124, 16, .black, mono: false)
            text("Transfer to Dana Whitfield · $250.00 · Rent share", 60, 156, 15, .darkGray, mono: false)
            text("Card ending 4242 · Contact support@bank.example.com", 60, 186, 15, .darkGray, mono: false)
            text("Your advisor", 900, 250, 15, .black, mono: false, bold: true)
            if faces, let photos = facePhotos, photos.count >= 2 {
                // Public-domain portraits (NASA, via Wikimedia Commons), passed with --faces; never committed.
                NSImage(cgImage: photos[0], size: .zero).draw(in: NSRect(x: 900 * s, y: (280 - scroll) * s, width: 160 * s, height: 200 * s))
                NSImage(cgImage: photos[1], size: .zero).draw(in: NSRect(x: 60 * s, y: (230 - scroll) * s, width: 64 * s, height: 80 * s))
            } else if faces {
                // Fallback stand-ins: emoji faces rendered by the system font (Vision does not count these as faces).
                ("🧑🏽" as NSString).draw(at: NSPoint(x: 880 * s, y: (280 - scroll) * s), withAttributes: [.font: NSFont.systemFont(ofSize: 150 * s)])
                ("👩🏻‍🦰" as NSString).draw(at: NSPoint(x: 80 * s, y: (300 - scroll) * s), withAttributes: [.font: NSFont.systemFont(ofSize: 110 * s)])
            }
            for i in 0..<6 { text("Oct \(13 - i) · Card purchase · Café Lumen · $\(4 + i).50", 60, 470 + CGFloat(i) * 26, 14, .darkGray, mono: false) }
            text(clock, 1220, 6, 12, .darkGray, mono: false)
        }
        return true
    }
    var r = NSRect(origin: .zero, size: size)
    return image.cgImage(forProposedRect: &r, context: nil, hints: nil)!
}

func frame(_ kind: FrameKind, _ scale: CGFloat) -> Frame {
    let meta: (String, String) = switch kind {
    case .terminal: ("Terminal", "zeus — zsh")
    case .xcode: ("Xcode", "ManagedSessionController.swift — Zeus")
    case .safari: ("Safari", "Northwind Bank — Checking")
    }
    return Frame(kind: kind, scale: scale, image: draw(kind, scale: scale), app: meta.0, window: meta.1)
}

// MARK: - Helpers

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
@discardableResult
func time<T>(_ label: String, runs: Int, _ body: () async throws -> T) async -> T? {
    var times: [Double] = []; var last: T?
    for i in 0..<runs {
        let clock = ContinuousClock(); let start = clock.now
        do { last = try await body() } catch { print("  \(label) run \(i): ERROR \(error)"); return nil }
        times.append(ms(clock.now - start))
    }
    print(String(format: "  %@: first %.0f ms, median %.0f ms (n=%d)", label, times[0], median(times), runs))
    return last
}

/// Sensitive by stage-1 rules (the same families the Redactor uses): emails, tokens, card/account numbers, money, URLs with paths.
let sensitive = try! NSRegularExpression(pattern: #"[\w.+-]+@[\w-]+\.[\w.]+|sk-[A-Za-z0-9-]{10,}|Bearer|\b\d{4}( ?\d{4}){2,3}\b|\b(ending|Account) \d{4}|\$[\d,]+\.\d\d|Dana Whitfield|Sam Okafor"#)
func isSensitive(_ s: String) -> Bool { sensitive.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

/// OCR lines with their pixel rects (top-left origin).
func ocr(_ image: CGImage, level: RecognizeTextRequest.RecognitionLevel = .accurate) async throws -> [(String, CGRect)] {
    var req = RecognizeTextRequest(); req.recognitionLevel = level
    let size = CGSize(width: image.width, height: image.height)
    return try await req.perform(on: image).compactMap { o in
        guard let s = o.topCandidates(1).first?.string else { return nil }
        return (s, o.boundingBox.toImageCoordinates(size, origin: .upperLeft))
    }
}

enum Cover: String, CaseIterable { case gaussian8 = "Gaussian blur r=8", gaussian20 = "Gaussian blur r=20", pixellate = "Pixellate 16 px", fill = "Solid fill" }

/// Covers `rects` (top-left origin, pixels), padded by 4 px, and returns the new frame.
func cover(_ image: CGImage, _ rects: [CGRect], with style: Cover, context: CIContext) -> CGImage {
    let base = CIImage(cgImage: image)
    let h = CGFloat(image.height)
    var out = base
    for r in rects {
        let flipped = CGRect(x: r.minX - 4, y: h - r.maxY - 4, width: r.width + 8, height: r.height + 8).integral
        let patch: CIImage
        switch style {
        case .gaussian8, .gaussian20:
            let f = CIFilter.gaussianBlur(); f.inputImage = base.clampedToExtent(); f.radius = style == .gaussian8 ? 8 : 20
            patch = f.outputImage!.cropped(to: flipped)
        case .pixellate:
            let f = CIFilter.pixellate(); f.inputImage = base.clampedToExtent(); f.scale = 16; f.center = flipped.origin
            patch = f.outputImage!.cropped(to: flipped)
        case .fill:
            patch = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: flipped)
        }
        out = patch.composited(over: out)
    }
    return context.createCGImage(out, from: base.extent)!
}

/// 64-bit difference hash: 9×8 grayscale, compare horizontal neighbours.
func dHash(_ image: CGImage) -> UInt64 {
    let w = 9, h = 8
    var pixels = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var hash: UInt64 = 0
    for y in 0..<h { for x in 0..<8 { hash = (hash << 1) | (pixels[y * w + x] < pixels[y * w + x + 1] ? 1 : 0) } }
    return hash
}
func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

/// Mean absolute difference over a 64×40 thumbnail, 0…255: a second "changed?" signal that dHash can't give.
func thumbDiff(_ a: CGImage, _ b: CGImage) -> Double {
    func thumb(_ i: CGImage) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 64 * 40)
        let c = CGContext(data: &p, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        c.draw(i, in: CGRect(x: 0, y: 0, width: 64, height: 40)); return p
    }
    let x = thumb(a), y = thumb(b)
    return Double(zip(x, y).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(x.count)
}

func write(_ image: CGImage, _ name: String, to dir: String?) {
    guard let dir else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}

// MARK: - Main

let args = CommandLine.arguments
let runs = Int(args.dropFirst().first ?? "5") ?? 5
let outDir: String? = args.firstIndex(of: "--write").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
if let outDir { try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
let ci = CIContext()
if let i = args.firstIndex(of: "--faces"), args.indices.contains(i + 1) {
    let dir = URL(fileURLWithPath: args[i + 1])
    facePhotos = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        .compactMap { CGImageSourceCreateWithURL($0 as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
    print("face photos: \(facePhotos?.count ?? 0)")
}

print("== Frames (synthetic)")
var frames: [Frame] = []
for scale in [1.0, 2.0] as [CGFloat] { for kind in FrameKind.allCases { frames.append(frame(kind, scale)) } }
for f in frames where f.scale == 1 { write(f.image, "frame-\(f.kind.rawValue)", to: outDir) }

print("\n== Faces and people")
for f in frames {
    let faces = await time("\(f.label) faces", runs: runs) { try await DetectFaceRectanglesRequest().perform(on: f.image) }
    let humans = await time("\(f.label) humans (upper body)", runs: runs) { try await DetectHumanRectanglesRequest().perform(on: f.image) }
    print("    → \(faces?.count ?? -1) faces, \(humans?.count ?? -1) humans")
}

if let safari = frames.first(where: { $0.kind == .safari && $0.scale == 1 }) {
    let faces = (try? await DetectFaceRectanglesRequest().perform(on: safari.image)) ?? []
    let size = CGSize(width: safari.image.width, height: safari.image.height)
    let rects = faces.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft).insetBy(dx: -0.25 * $0.boundingBox.cgRect.width * size.width, dy: -0.25 * $0.boundingBox.cgRect.height * size.height) }
    for style in [Cover.gaussian20, .pixellate, .fill] {
        let covered = cover(safari.image, rects, with: style, context: ci)
        let again = (try? await DetectFaceRectanglesRequest().perform(on: covered)) ?? []
        print("  safari faces covered with \(style.rawValue): \(faces.count) → \(again.count) detectable after cover")
        if style == .pixellate { write(covered, "covered-faces-pixellate", to: outDir) }
    }
}

print("\n== OCR")
var ocrByFrame: [String: [(String, CGRect)]] = [:]
for f in frames {
    let accurate = await time("\(f.label) accurate", runs: runs) { try await ocr(f.image) } ?? []
    let fast = await time("\(f.label) fast", runs: runs) { try await ocr(f.image, level: .fast) } ?? []
    let chars = accurate.map(\.0.count).reduce(0, +)
    print("    → accurate \(accurate.count) lines / \(chars) chars; fast \(fast.count) lines; sensitive lines \(accurate.filter { isSensitive($0.0) }.count)")
    ocrByFrame[f.label] = accurate
}

print("\n== Covering sensitive OCR regions, then re-OCR (is anything recoverable?)")
for f in frames where f.scale == 1 {
    let lines = ocrByFrame[f.label] ?? []
    let hits = lines.filter { isSensitive($0.0) }
    let secrets = hits.map(\.0)
    for style in Cover.allCases {
        let covered = cover(f.image, hits.map(\.1), with: style, context: ci)
        let again = (try? await ocr(covered)) ?? []
        // A leak is any sensitive match (email, token, number, name) from the original lines that re-OCR can still read.
        let originals = hits.flatMap { line in sensitive.matches(in: line.0, range: NSRange(line.0.startIndex..., in: line.0)).compactMap { Range($0.range, in: line.0).map { String(line.0[$0]) } } }
        let reread = again.map(\.0).joined(separator: "\n")
        let leaks = originals.filter { $0.count >= 4 && reread.contains($0) }.map { ($0, CGRect.zero) }
        print("  \(f.label) · \(style.rawValue): covered \(hits.count) lines, re-OCR leaks \(leaks.count)" + (leaks.isEmpty ? "" : ": " + leaks.map(\.0).joined(separator: " | ")))
        if style == .fill || style == .gaussian8 { write(covered, "covered-\(f.kind.rawValue)-\(style == .fill ? "fill" : "blur8")", to: outDir) }
    }
}
let t = ContinuousClock(); let t0 = t.now
for _ in 0..<runs { _ = cover(frames[2].image, (ocrByFrame[frames[2].label] ?? []).map(\.1), with: .fill, context: ci) }
print(String(format: "  cover cost (fill, all lines, 1280×800): %.1f ms per frame", ms(t.now - t0) / Double(runs)))

print("\n== Unchanged-frame check (dHash, 64 bit)")
for kind in FrameKind.allCases {
    let base = draw(kind, scale: 1)
    let same = draw(kind, scale: 1)
    let clock = draw(kind, scale: 1, clock: "09:42")
    let s8 = draw(kind, scale: 1, scroll: 8), s20 = draw(kind, scale: 1, scroll: 20), s80 = draw(kind, scale: 1, scroll: 80)
    let other = draw(FrameKind.allCases[(FrameKind.allCases.firstIndex(of: kind)! + 1) % 3], scale: 1)
    let h = dHash(base)
    func row(_ name: String, _ img: CGImage) -> String { String(format: "%@ d=%d diff=%.2f", name, distance(h, dHash(img)), thumbDiff(base, img)) }
    print("  \(kind.rawValue): " + [row("identical", same), row("clock", clock), row("scroll 8pt", s8), row("scroll 20pt", s20), row("scroll 80pt", s80), row("other app", other)].joined(separator: " · "))
}
for scale in [1.0, 2.0] as [CGFloat] {
    let fs = frames.filter { $0.scale == scale }
    let h0 = t.now; for f in fs { _ = dHash(f.image) }
    print(String(format: "  dHash cost at %.0f×%.0f: %.2f ms per frame (straight from the full frame)", 1280 * scale, 800 * scale, ms(t.now - h0) / Double(fs.count)))
    let h1 = t.now
    for f in fs {
        var thumb = [UInt8](repeating: 0, count: 64 * 40)
        let c = CGContext(data: &thumb, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        c.interpolationQuality = .low; c.draw(f.image, in: CGRect(x: 0, y: 0, width: 64, height: 40))
        _ = dHash(c.makeImage()!)
    }
    print(String(format: "  thumbnail (64×40, low quality) + dHash + diff input at %.0f×%.0f: %.2f ms per frame", 1280 * scale, 800 * scale, ms(t.now - h1) / Double(fs.count)))
}

print("\n== Description from text (on-device model)")
let model = SystemLanguageModel.default
print("  availability: \(model.availability)")
if model.isAvailable {
    let instructions = "You describe one Mac window for a private activity journal. Use only what the text shows. Never repeat names of people, numbers, addresses or secrets."
    for f in frames where f.scale == 1 {
        let lines = (ocrByFrame[f.label] ?? []).map { isSensitive($0.0) ? "‹redacted›" : $0.0 }
        let ocrText = lines.joined(separator: "\n")
        if let n = try? await model.tokenCount(for: Prompt(ocrText)) { print("  \(f.label): OCR text \(n) tokens") }
        let a = await time("\(f.label) (a) OCR only", runs: 3) {
            try await LanguageModelSession(model: model, instructions: instructions)
                .respond(to: "Text on screen:\n" + ocrText, generating: FrameDescription.self, options: GenerationOptions(samplingMode: .greedy)).content
        }
        if let a { print("    → \(a)") }
        let b = await time("\(f.label) (b) OCR + app and window title", runs: 3) {
            try await LanguageModelSession(model: model, instructions: instructions)
                .respond(to: "App: \(f.app)\nWindow title: \(f.window)\nText on screen:\n" + ocrText, generating: FrameDescription.self, options: GenerationOptions(samplingMode: .greedy)).content
        }
        if let b { print("    → \(b)") }
        let covered = cover(f.image, (ocrByFrame[f.label] ?? []).filter { isSensitive($0.0) }.map(\.1), with: .fill, context: ci)
        let c = await time("\(f.label) (c) covered image + app and title", runs: 3) {
            try await LanguageModelSession(model: model, instructions: instructions)
                .respond(generating: FrameDescription.self, options: GenerationOptions(samplingMode: .greedy)) {
                    "App: \(f.app)\nWindow title: \(f.window)\nDescribe this window."
                    Attachment(covered)
                }.content
        }
        if let c { print("    → \(c)") }
    }
}

print("\n== Hard stops")
// Camera in use: CoreMediaIO, no camera permission needed, never opens the camera.
var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
var size: UInt32 = 0
let ct = ContinuousClock(); let c0 = ct.now
CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size)
var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &devices)
var running = 0
for d in devices {
    var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    var value: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    if CMIOObjectGetPropertyData(d, &a, 0, nil, s, &s, &value) == 0, value != 0 { running += 1 }
}
print(String(format: "  camera: %d video devices, %d running somewhere (kCMIODevicePropertyDeviceIsRunningSomewhere), %.2f ms", devices.count, running, ms(ct.now - c0)))
// Mirroring: CoreGraphics, no permission.
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
for id in ids.prefix(Int(count)) {
    print("  display: inMirrorSet=\(CGDisplayIsInMirrorSet(id) != 0) mirrorsAnother=\(CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay) builtin=\(CGDisplayIsBuiltin(id) != 0)")
}
print("  secure input now: \(IsSecureEventInputEnabled())")
