import AppKit
import CoreGraphics
import ZeusProtocol
import CoreText
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign
import ZeusSprites

// zeus-sprites: validate character files and render review sheets.

let usage = """
usage:
  zeus-sprites validate [dir]
      Validate every *.json character in dir (default: the bundled characters).
  zeus-sprites sheet <out.png> [--scale N (default: each character's preferredScale)] [--characters id,id] [--times t,t,…] [--dir D] [--guides]
      Contact sheet: one row per character × state, one column per time sample.
  zeus-sprites gif <out.gif> [--character id] [--scale N] [--seconds S] [--fps F] [--dir D]
      Animated GIF of every state side by side.
  zeus-sprites roster <out.png> [--states s,s,…] [--columns N] [--dir D]
      Overview: every character as a tile showing a few states at its preferredScale.
  zeus-sprites conversation <out.png>
      Render the conversation panel gallery (real AppKit text fields, so composers draw).
  zeus-sprites peek <out.png>
      Render peek-bubble scenes (bubble + talking Zeus) in both appearances.
  zeus-sprites typing <out.png> [--character id]
      Typing-indicator gallery (D15), plus the character's thinking and working states at its preferredScale.
  zeus-sprites dmg <out-dir> --app-icon <AppIcon.appiconset> [--preview <out.png>]
      DMG installer art (D17): background.png, background@2x.png and ZeusVolume.icns.
  zeus-sprites appicon <AppIcon.appiconset> [--dir <characters>]
      The app icon (F11): full-bleed 64/32/16 px grids, every size in the set.
  zeus-sprites fonts <out.png> --fonts-dir D
      Font spike (D9): render the same UI sample in each candidate pixel font.
  zeus-sprites bench [--seconds S] [--characters ids] [--states s,s]
      Renderer micro-benchmark: renders per second, 12 Hz idle timeline (per character × state).
  zeus-sprites gallery <out.png> [--scale N]
      Render the ZeusDesign component gallery (both appearances, both fonts).
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

/// Parses `--flag value` / `--flag` options after the positional arguments.
struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, flags known: Set<String>) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if known.contains(name) {
                    flags.insert(name)
                } else if let value = it.next() {
                    values[name] = value
                } else {
                    throw CLIError(description: "missing value for \(arg)")
                }
            } else {
                positional.append(arg)
            }
        }
    }

    func int(_ name: String, default d: Int) throws -> Int {
        guard let v = values[name] else { return d }
        guard let n = Int(v), n > 0 else { throw CLIError(description: "--\(name) must be a positive integer") }
        return n
    }

    func double(_ name: String, default d: Double) throws -> Double {
        guard let v = values[name] else { return d }
        guard let n = Double(v), n > 0 else { throw CLIError(description: "--\(name) must be a positive number") }
        return n
    }
}

func loadCharacters(dir: String?, ids: [String]?) throws -> [SpriteCharacter] {
    var all: [SpriteCharacter]
    if let dir {
        let (characters, issues) = CharacterLibrary.loadDirectory(URL(fileURLWithPath: dir))
        issues.forEach { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
        all = characters
    } else {
        let library = CharacterLibrary.load(userDirectory: nil)
        library.issues.forEach { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
        all = library.characters
    }
    if let ids {
        all = try ids.map { id in
            guard let c = all.first(where: { $0.id == id }) else { throw CLIError(description: "no character \"\(id)\"") }
            return c
        }
    }
    guard !all.isEmpty else { throw CLIError(description: "no characters loaded") }
    return all
}

// MARK: - Drawing helpers

let sheetBackground = CGColor(srgbRed: 0.13, green: 0.14, blue: 0.19, alpha: 1)
let checkerA = CGColor(srgbRed: 0.24, green: 0.27, blue: 0.35, alpha: 1)
let checkerB = CGColor(srgbRed: 0.27, green: 0.30, blue: 0.39, alpha: 1)
let labelColor = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.97, alpha: 1)
let dimLabelColor = CGColor(srgbRed: 0.62, green: 0.65, blue: 0.75, alpha: 1)

/// A top-left-origin drawing surface over a bitmap CGContext.
struct Canvas {
    let context: CGContext
    let width: Int
    let height: Int

    init(width: Int, height: Int) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CLIError(description: "couldn't create a \(width)×\(height) bitmap") }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        context = ctx
        self.width = width
        self.height = height
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    func image(_ image: CGImage, _ x: Int, _ y: Int, scale: Int) {
        let w = image.width * scale, h = image.height * scale
        context.draw(image, in: CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    /// Draws a pixel checkerboard behind a sprite so transparency and canvas bounds are visible.
    func checker(_ x: Int, _ y: Int, cols: Int, rows: Int, cell: Int) {
        for r in 0..<rows {
            for c in 0..<cols {
                fill(x + c * cell, y + r * cell, cell, cell, (r + c).isMultiple(of: 2) ? checkerA : checkerB)
            }
        }
    }

    /// Draws text with its top-left at (x, y).
    func text(_ string: String, _ x: Int, _ y: Int, size: CGFloat, color: CGColor, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.setShouldAntialias(true)
        context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - y) - CTFontGetAscent(font))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    func makeImage() throws -> CGImage {
        guard let image = context.makeImage() else { throw CLIError(description: "couldn't snapshot bitmap") }
        return image
    }
}

func writeImages(_ images: [CGImage], to path: String, type: UTType, frameDelay: Double? = nil) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil) else {
        throw CLIError(description: "can't write \(path)")
    }
    if let frameDelay {
        let gif = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, gif as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay, kCGImagePropertyGIFUnclampedDelayTime: frameDelay]]
        images.forEach { CGImageDestinationAddImage(dest, $0, frame as CFDictionary) }
    } else {
        images.forEach { CGImageDestinationAddImage(dest, $0, nil) }
    }
    guard CGImageDestinationFinalize(dest) else { throw CLIError(description: "failed writing \(path)") }
}

func stateLabel(_ character: SpriteCharacter, _ state: AvatarState) -> (String, String?) {
    let resolved = character.resolvedState(for: state)
    return (state.spriteKey, resolved == state ? nil : "→ \(resolved.spriteKey)")
}

// MARK: - Commands

func validate(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    let url: URL
    if let dir = opts.positional.first {
        url = URL(fileURLWithPath: dir)
    } else if let bundled = CharacterLibrary.bundledDirectory {
        url = bundled
    } else {
        throw CLIError(description: "no bundled Characters directory")
    }
    let (characters, issues) = CharacterLibrary.loadDirectory(url)
    issues.forEach { print($0) }
    for c in characters {
        let defined = c.definedStates.map(\.spriteKey).joined(separator: " ")
        print("ok  \(c.id) (\(c.name)) canvas \(c.canvasSize.width)×\(c.canvasSize.height) anchor (\(c.anchor.x),\(c.anchor.y)) states: \(defined)")
    }
    let errors = issues.filter { $0.severity == .error }.count
    print("\(characters.count) character(s) ok, \(errors) error(s), \(issues.count - errors) warning(s)")
    return errors == 0 && !characters.isEmpty ? 0 : 1
}

func sheet(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: ["guides"])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    // Without --scale, each character renders at its preferredScale (true relative on-screen size).
    let fixedScale = opts.values["scale"] == nil ? nil : try opts.int("scale", default: 4)
    func scale(_ c: SpriteCharacter) -> Int { fixedScale ?? c.preferredScale }
    let times = try (opts.values["times"] ?? "0,0.4,0.85,1.3,1.8,2.45,3.1,3.9").split(separator: ",").map { s in
        guard let t = Double(s) else { throw CLIError(description: "bad --times value \"\(s)\"") }
        return t
    }
    let characters = try loadCharacters(dir: opts.values["dir"], ids: opts.values["characters"]?.split(separator: ",").map(String.init))

    let pad = 12, labelWidth = 150, headerHeight = 40, timeHeader = 22
    let cellW = characters.map { $0.canvasSize.width * scale($0) }.max() ?? 0
    let blocks = characters.map { (character: $0, rowHeight: $0.canvasSize.height * scale($0)) }
    let width = pad + labelWidth + times.count * (cellW + pad)
    let height = pad + timeHeader + blocks.reduce(0) { $0 + headerHeight + AvatarState.spriteOrder.count * ($1.rowHeight + pad) } + pad
    let canvas = try Canvas(width: width, height: height)
    canvas.fill(0, 0, width, height, sheetBackground)

    for (i, t) in times.enumerated() {
        canvas.text(String(format: "t=%.2fs", t), pad + labelWidth + i * (cellW + pad), pad, size: 11, color: dimLabelColor)
    }
    var y = pad + timeHeader
    for block in blocks {
        let c = block.character
        canvas.text("\(c.name) — \(c.id)  \(c.canvasSize.width)×\(c.canvasSize.height)px @\(scale(c))x", pad, y + 8, size: 15, color: labelColor, bold: true)
        y += headerHeight
        for state in AvatarState.spriteOrder {
            let (label, note) = stateLabel(c, state)
            canvas.text(label, pad, y + 6, size: 13, color: labelColor, bold: true)
            if let note { canvas.text(note, pad, y + 24, size: 11, color: dimLabelColor) }
            for (i, t) in times.enumerated() {
                let x = pad + labelWidth + i * (cellW + pad)
                let s = scale(c)
                canvas.checker(x, y, cols: c.canvasSize.width, rows: c.canvasSize.height, cell: s)
                canvas.image(SpriteRenderer.render(c, state: state, time: t), x, y, scale: s)
                if opts.flags.contains("guides") {
                    canvas.fill(x + c.anchor.x * s, y + c.anchor.y * s - 1, s, 2, CGColor(srgbRed: 1, green: 0.2, blue: 0.3, alpha: 1))
                }
            }
            y += block.rowHeight + pad
        }
    }
    try writeImages([canvas.makeImage()], to: out, type: .png)
    print("wrote \(out) (\(width)×\(height))")
    return 0
}

func gif(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    let scale = try opts.int("scale", default: 3)
    let seconds = try opts.double("seconds", default: 6)
    let fps = try opts.double("fps", default: 20)
    let characters = try loadCharacters(dir: opts.values["dir"], ids: [opts.values["character"] ?? CharacterLibrary.defaultCharacterID])
    let c = characters[0]

    let pad = 10, labelHeight = 30
    let cellW = c.canvasSize.width * scale, cellH = c.canvasSize.height * scale
    let states = AvatarState.spriteOrder
    let width = pad + states.count * (cellW + pad)
    let height = pad + labelHeight + cellH + pad
    let frameCount = Int(seconds * fps)
    var frames: [CGImage] = []
    for f in 0..<frameCount {
        let t = Double(f) / fps
        let canvas = try Canvas(width: width, height: height)
        canvas.fill(0, 0, width, height, sheetBackground)
        for (i, state) in states.enumerated() {
            let x = pad + i * (cellW + pad)
            let (label, note) = stateLabel(c, state)
            canvas.text(label, x, pad, size: 12, color: labelColor, bold: true)
            if let note { canvas.text(note, x, pad + 14, size: 10, color: dimLabelColor) }
            canvas.fill(x, pad + labelHeight, cellW, cellH, checkerA)
            canvas.image(SpriteRenderer.render(c, state: state, time: t), x, pad + labelHeight, scale: scale)
        }
        frames.append(try canvas.makeImage())
    }
    try writeImages(frames, to: out, type: .gif, frameDelay: 1 / fps)
    print("wrote \(out) (\(frameCount) frames, \(width)×\(height))")
    return 0
}

func roster(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    let states = try (opts.values["states"] ?? "idle,alert,happy").split(separator: ",").map { key in
        guard let state = AvatarState(spriteKey: String(key)) else { throw CLIError(description: "unknown state \(key)") }
        return state
    }
    let columns = try opts.int("columns", default: 3)
    let characters = try loadCharacters(dir: opts.values["dir"], ids: nil)
    // A moment in each state's loop that shows it well (mid-hop, emote fully drawn).
    let sampleTime: [AvatarState: TimeInterval] = [.idle: 0.4, .alert: 0.25, .happy: 0.3, .working: 0.5, .thinking: 1.0]

    let pad = 14, gap = 6, labelHeight = 26
    let cellW = characters.map { $0.canvasSize.width * $0.preferredScale }.max() ?? 0
    let cellH = characters.map { $0.canvasSize.height * $0.preferredScale }.max() ?? 0
    let tileW = states.count * cellW + (states.count - 1) * gap
    let tileH = labelHeight + cellH
    let rows = (characters.count + columns - 1) / columns
    let width = pad + columns * (tileW + pad)
    let height = pad + rows * (tileH + pad) + 20
    let canvas = try Canvas(width: width, height: height)
    canvas.fill(0, 0, width, height, sheetBackground)
    for (n, c) in characters.enumerated() {
        let x0 = pad + (n % columns) * (tileW + pad)
        let y0 = pad + (n / columns) * (tileH + pad)
        canvas.text(c.name, x0, y0 + 2, size: 15, color: labelColor, bold: true)
        canvas.text(c.id, x0 + 8 + c.name.count * 10, y0 + 5, size: 11, color: dimLabelColor)
        for (i, state) in states.enumerated() {
            let s = c.preferredScale
            let w = c.canvasSize.width * s, h = c.canvasSize.height * s
            let x = x0 + i * (cellW + gap)
            let y = y0 + labelHeight
            canvas.fill(x, y, cellW, cellH, checkerA)
            // Bottom-aligned on the anchor line, horizontally centered: how they'd stand on screen.
            canvas.image(SpriteRenderer.render(c, state: state, time: sampleTime[state] ?? 0.4),
                         x + (cellW - w) / 2, y + cellH - h, scale: s)
            if n < columns { canvas.text(state.spriteKey, x + 4, y + 4, size: 10, color: dimLabelColor) }
        }
    }
    try writeImages([canvas.makeImage()], to: out, type: .png)
    print("wrote \(out) (\(width)×\(height))")
    return 0
}

@MainActor
func gallery(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    guard ZeusFonts.registerBundled() else { throw CLIError(description: "couldn't register the bundled pixel font") }
    let renderer = ImageRenderer(content: ZeusComponentGallery(snapshot: true))
    renderer.scale = CGFloat(try opts.int("scale", default: 2))
    guard let image = renderer.cgImage else { throw CLIError(description: "couldn't render the gallery") }
    try writeImages([image], to: out, type: .png)
    print("wrote \(out) (\(image.width)×\(image.height))")
    return 0
}

/// Renders through NSHostingView, not ImageRenderer: ImageRenderer can't draw text fields.
@MainActor
func conversation(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    guard ZeusFonts.registerBundled() else { throw CLIError(description: "couldn't register the bundled pixel font") }
    NSApplication.shared.setActivationPolicy(.prohibited)
    let host = NSHostingView(rootView: ZeusConversationGallery())
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CLIError(description: "couldn't allocate bitmap") }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let image = rep.cgImage else { throw CLIError(description: "couldn't render the conversation gallery") }
    try writeImages([image], to: out, type: .png)
    print("wrote \(out) (\(image.width)×\(image.height))")
    return 0
}

/// One peek scene: a bubble pointing at a talking Zeus, as it would sit in the screen corner.
struct PeekScene: View {
    let zeus: SpriteCharacter
    let caption: String
    let side: Bool
    let bubble: (ZeusDialogTail) -> ZeusPeekBubble

    var body: some View {
        let scale = CGFloat(zeus.preferredScale)
        let w = CGFloat(zeus.canvasSize.width) * scale, h = CGFloat(zeus.canvasSize.height) * scale
        let sprite = Image(decorative: SpriteRenderer.render(zeus, state: .talking, time: 0.15, options: .init(showEmote: false)), scale: 1)
            .resizable().interpolation(.none).frame(width: w, height: h)
        VStack(alignment: .leading, spacing: 8) {
            Text(caption).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if side {
                HStack(alignment: .top, spacing: -6) {
                    sprite
                    bubble(ZeusDialogTail(edge: .leading, offset: 34)).padding(.top, 44)
                }
            } else {
                // Zeus's canvas has ~45 pt of headroom (raised bolt, emotes); tuck him up under the tail.
                VStack(alignment: .leading, spacing: -47) {
                    bubble(ZeusDialogTail(edge: .bottom, offset: 136 + w / 2))
                    sprite.padding(.leading, 136)
                }
            }
        }
    }
}

struct PeekGallery: View {
    let zeus: SpriteCharacter

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(.dark)
            column(.light)
        }
        .fixedSize()
    }

    private func column(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            PeekScene(zeus: zeus, caption: "message", side: false) { tail in
                ZeusPeekBubble(title: "Draft ready", body: "Your Q3 talk outline is in **Keynote**. Want a look?",
                               attachmentCount: 1, tail: tail, onOpen: {}, onClose: {})
            }
            PeekScene(zeus: zeus, caption: "question with options · answers in place", side: false) { tail in
                ZeusPeekBubble(title: "Talk tomorrow", body: "Your talk on Q3 planning is tomorrow at 10:00. Have you started on it?",
                               options: [CardOption(id: "yes", label: "Yes", style: .secondary),
                                         CardOption(id: "no", label: "No", style: .primary),
                                         CardOption(id: "later", label: "Later", style: .secondary)],
                               tail: tail, onOpen: {}, onClose: {})
            }
            PeekScene(zeus: zeus, caption: "long message · mid-typewriter (30%) · truncates at 3 lines", side: false) { tail in
                ZeusPeekBubble(title: "Inbox summary",
                               body: "Three things need you today: Sam wants the budget numbers by noon, the design review moved to 3pm, and your flight to Denver is delayed by forty minutes, so I've nudged the airport ride.",
                               tail: tail, reveal: .fraction(0.3), onOpen: {}, onClose: {})
            }
            PeekScene(zeus: zeus, caption: "+2 more · high priority (gold, stays) · text reply", side: false) { tail in
                ZeusPeekBubble(title: "Ship the build?", body: "Tests pass on **main**. Anything to add to the release notes?",
                               acceptsText: true, moreCount: 2, highPriority: true, tail: tail, onOpen: {}, onClose: {})
            }
            PeekScene(zeus: zeus, caption: "beside Zeus (no room above) · leading tail", side: true) { tail in
                ZeusPeekBubble(title: nil, body: "Reminder set for 9:00.", tail: tail, onOpen: {}, onClose: {})
            }
        }
        .padding(28)
        .frame(width: 520, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(scheme == .dark ? Color(hex: 0x3B4256) : Color(hex: 0xD9DEE8))
        .environment(\.colorScheme, scheme)
    }
}

@MainActor
func peek(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    guard ZeusFonts.registerBundled() else { throw CLIError(description: "couldn't register the bundled pixel font") }
    let zeus = try loadCharacters(dir: opts.values["dir"], ids: ["zeus"])[0]
    NSApplication.shared.setActivationPolicy(.prohibited)
    let host = NSHostingView(rootView: PeekGallery(zeus: zeus))
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CLIError(description: "couldn't allocate bitmap") }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let image = rep.cgImage else { throw CLIError(description: "couldn't render peek scenes") }
    try writeImages([image], to: out, type: .png)
    print("wrote \(out) (\(image.width)×\(image.height))")
    return 0
}

/// Thinking and working at the default (preferred) scale, a few moments each, on both backgrounds:
/// the panel-closed half of CONTRACT §10.8 (§7 rule 3b).
struct ActivityStatesStrip: View {
    let character: SpriteCharacter
    let times: [Double] = [0, 0.5, 1.0, 1.5]

    var body: some View {
        let scale = CGFloat(character.preferredScale)
        let w = CGFloat(character.canvasSize.width) * scale, h = CGFloat(character.canvasSize.height) * scale
        VStack(alignment: .leading, spacing: 16) {
            ForEach([AvatarState.thinking, .working], id: \.self) { state in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(character.name) · \(state.rawValue) · ×\(character.preferredScale)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        ForEach([Color(hex: 0x3B4256), Color(hex: 0xD9DEE8)], id: \.self) { bg in
                            ForEach(times, id: \.self) { t in
                                Image(decorative: SpriteRenderer.render(character, state: state, time: t), scale: 1)
                                    .resizable().interpolation(.none).frame(width: w, height: h)
                                    .background(bg)
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
        .background(Color(hex: 0x2A2F3D))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
func typing(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first else { throw CLIError(description: usage) }
    guard ZeusFonts.registerBundled() else { throw CLIError(description: "couldn't register the bundled pixel font") }
    let character = try loadCharacters(dir: opts.values["dir"], ids: [opts.values["character"] ?? "zeus"])[0]
    let content = VStack(alignment: .leading, spacing: 0) {
        ZeusTypingGallery(frozen: true)
        ActivityStatesStrip(character: character)
    }
    .fixedSize()
    .background(Color(hex: 0x2A2F3D))
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage else { throw CLIError(description: "couldn't render the typing gallery") }
    try writeImages([image], to: out, type: .png)
    print("wrote \(out) (\(image.width)×\(image.height))")
    return 0
}

/// A font under evaluation: file, family, crisp sizes per role, and its measured glyph distinctness.
struct FontCandidate {
    let label: String
    let file: String?
    let override: ZeusFontOverride?
    let scores: String
    let note: String
}

struct FontSample: View {
    let candidate: FontCandidate
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let options = [CardOption(id: "ship", label: "Ship it", style: .primary), CardOption(id: "wait", label: "Not yet", style: .secondary)]
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.label).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                Text(candidate.scores).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0xA9A3C7))
                Text(candidate.note).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0xA9A3C7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 64, alignment: .top)
            Text("Zeus  Z2 S5 0O 1lI 8B").zeusFont(.title).foregroundStyle(Color(hex: 0xF6C544))
            HStack(spacing: 10) {
                Text("+2 more").zeusFont(.badge).padding(.horizontal, 4).background(Color(hex: 0x3A3354))
                Text("⌘2").zeusFont(.badge)
                Text("62%").zeusFont(.caption)
                ZeusBadge(count: 3)
                ZeusBadge(count: 12)
            }
            .foregroundStyle(Color(hex: 0xF4F1FF))
            ZeusPeekBubble(title: "Talk tomorrow", body: "Your talk on Q3 planning is tomorrow at 10:00. Started on it?",
                           options: [CardOption(id: "y", label: "Yes", style: .secondary), CardOption(id: "n", label: "No", style: .primary)],
                           moreCount: 2, tail: ZeusDialogTail(edge: .bottom, offset: 200), onOpen: {}, onClose: {})
            VStack(spacing: 8) {
                ZeusSessionLabel("Claude · Zeus", colorIndex: 0).frame(maxWidth: .infinity, alignment: .leading)
                ZeusBubble(.agent) {
                    ZeusBubbleHeader(title: "Ship the build?", trailing: "8:40")
                    Text("Tests pass on main. Tag v0.3 and upload it?")
                    ZeusOptionButtons(options, state: .open(shortcuts: true)) { _ in }
                }
                ZeusBubble(.user) { Text("Yes, ship it at 5:00 PM.") }
                ZeusBubble(.agent) {
                    ZeusBubbleHeader(title: "Uploading v0.3", trailing: "8:42")
                    ZeusProgressRow(value: 0.62)
                }
                ZeusComposer(text: $draft, placeholder: "Message Zeus…", replyingTo: "Ship the build?",
                             focus: $focused, onClearReply: {}, onSend: {})
            }
            .padding(10)
            .background(ZeusPalette.dark.panel)
        }
        .padding(20)
        .frame(width: 380, alignment: .topLeading)
        .environment(\.zeusFontOverride, candidate.override)
    }
}

@MainActor
func fonts(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let out = opts.positional.first, let dir = opts.values["fonts-dir"] else { throw CLIError(description: usage) }
    guard ZeusFonts.registerBundled() else { throw CLIError(description: "couldn't register the bundled pixel font") }
    let candidates = [
        FontCandidate(label: "Departure Mono (bundled)", file: nil, override: nil,
                      scores: "Z/2 0.52  S/5 0.22  0/O 0.14  l/I 0.13  8/B 0.14",
                      note: "16.5/11 pt · 11 px/em grid: crisp at 11, 16.5, 22 · has ⌘ · monospace"),
        FontCandidate(label: "Pixelify Sans (previous)", file: "PixelifySans-Variable.ttf",
                      override: ZeusFontOverride(family: "Pixelify Sans", sizes: [.title: 17, .body: 15, .caption: 13, .button: 14, .badge: 11]),
                      scores: "Z/2 0.10  S/5 0.31  0/O 0.00  l/I 0.86  8/B 0.09",
                      note: "17/15/13 pt · off-grid outlines · Z≈2, 0=O, 8≈B"),
        FontCandidate(label: "Monocraft", file: "Monocraft.ttf",
                      override: ZeusFontOverride(family: "Monocraft", sizes: [.title: 18, .body: 13.5, .caption: 12, .button: 13.5, .badge: 12]),
                      scores: "Z/2 0.39  S/5 0.12  0/O 0.16  l/I 0.59  8/B 0.47",
                      note: "18/13.5/12 pt · 18 px/em grid: crisp only at 9, 18 (13.5 is soft) · has ⌘ · monospace"),
        FontCandidate(label: "VT323", file: "VT323-Regular.ttf",
                      override: ZeusFontOverride(family: "VT323", sizes: [.title: 24, .body: 20, .caption: 17, .button: 18, .badge: 16]),
                      scores: "Z/2 0.39  S/5 0.38  0/O 0.44  l/I 0.11  8/B 0.49",
                      note: "24/20/17 pt (small x-height) · off-grid · terminal look"),
        FontCandidate(label: "Press Start 2P", file: "PressStart2P-Regular.ttf",
                      override: ZeusFontOverride(family: "Press Start 2P", sizes: [.title: 12, .body: 8, .caption: 8, .button: 8, .badge: 8]),
                      scores: "Z/2 0.23  S/5 0.34  0/O 0.30  l/I 0.10  8/B 0.30",
                      note: "12/8 pt · 8 px/em grid: crisp at 8, 12, 16 · very wide, heavy"),
    ]
    for c in candidates {
        guard let file = c.file else { continue }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            throw CLIError(description: "couldn't register \(url.path)")
        }
    }
    NSApplication.shared.setActivationPolicy(.prohibited)
    let view = HStack(alignment: .top, spacing: 0) { ForEach(candidates.indices, id: \.self) { FontSample(candidate: candidates[$0]) } }
        .background(Color(hex: 0x3B4256))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CLIError(description: "couldn't allocate bitmap") }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let image = rep.cgImage else { throw CLIError(description: "couldn't render fonts") }
    try writeImages([image], to: out, type: .png)
    print("wrote \(out) (\(image.width)×\(image.height))")
    return 0
}

/// Times the renderer the way the app calls it: a 12 Hz timeline per character × state.
/// Reports plain `render()`, `SpriteFrameCache.image()` (the live-view path), and `signature()` alone.
func bench(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    let seconds = try opts.double("seconds", default: 1)
    let characters = try loadCharacters(dir: opts.values["dir"], ids: opts.values["characters"]?.split(separator: ",").map(String.init))
    let states: [AvatarState] = try (opts.values["states"] ?? "idle,working,sleeping").split(separator: ",").map { key in
        guard let state = AvatarState(spriteKey: String(key)) else { throw CLIError(description: "unknown state \(key)") }
        return state
    }
    func measure(_ label: String, _ work: (SpriteCharacter, AvatarState, Double) -> Void) {
        var calls = 0, elapsed = 0.0
        for c in characters {
            for state in states {
                let budget = seconds / Double(characters.count * states.count)
                let start = Date()
                var t = 1000.0
                while Date().timeIntervalSince(start) < budget { work(c, state, t); t += 1.0 / 12; calls += 1 }
                elapsed += Date().timeIntervalSince(start)
            }
        }
        let per = elapsed / Double(calls) * 1_000_000
        print(String(format: "%-26@ %7.1f µs/call  → at 12 Hz ≈ %.3f%% of one core", label as NSString, per, per * 12 / 10_000))
    }
    measure("render()") { c, s, t in _ = SpriteRenderer.render(c, state: s, time: t) }
    var caches: [String: SpriteFrameCache] = [:]
    var hits = 0, total = 0
    measure("SpriteFrameCache.image()") { c, s, t in
        let key = "\(c.id).\(s)"
        let cache = caches[key] ?? SpriteFrameCache()
        caches[key] = cache
        let before = cache.rasterizedCount
        _ = cache.image(for: c, state: s, time: t)
        total += 1; if cache.rasterizedCount == before { hits += 1 }
    }
    print(String(format: "  cache reuse at 12 Hz: %.1f%% of ticks returned the previous/cached image", Double(hits) / Double(max(total, 1)) * 100))
    measure("signature() only") { c, s, t in _ = SpriteRenderer.signature(c, state: s, time: t) }
    return 0
}

// MARK: - Main

let arguments = CommandLine.arguments
do {
    let rest = arguments.dropFirst(2)
    let status: Int32
    switch arguments.dropFirst().first {
    case "validate": status = try validate(rest)
    case "sheet": status = try sheet(rest)
    case "gif": status = try gif(rest)
    case "gallery": status = try gallery(rest)
    case "roster": status = try roster(rest)
    case "conversation": status = try conversation(rest)
    case "peek": status = try peek(rest)
    case "typing": status = try typing(rest)
    case "dmg": status = try dmg(rest)
    case "appicon": status = try appicon(rest)
    case "fonts": status = try fonts(rest)
    case "bench": status = try bench(rest)
    default:
        print(usage)
        status = arguments.count > 1 ? 2 : 0
    }
    exit(status)
} catch {
    FileHandle.standardError.write(Data("zeus-sprites: \(error)\n".utf8))
    exit(1)
}
