import AppKit
import SwiftUI
import ZeusDesign

/// Converts the design system's document runs to native text without an HTML importer or network loader.
@MainActor enum DocumentTextStyling {
    static let anchorKey = NSAttributedString.Key("ZeusDocumentAnchor")
    private static let headingKey = NSAttributedString.Key("ZeusDocumentHeading")
    private struct Cached {
        let id: UUID; let revision: Int; let source: Bool
        let choice: ZeusFontChoice; let scale: ZeusFontScale; let palette: ZeusPalette; let width: CGFloat
        let value: NSAttributedString
    }
    private static var cache: [Cached] = []
    static func make(_ page: DocumentViewerModel.Page, revision: Int, choice: ZeusFontChoice, scale: ZeusFontScale, palette: ZeusPalette, width: CGFloat) -> NSAttributedString {
        if let hit = cache.first(where: { $0.id == page.id && $0.revision == revision && $0.source == page.source && $0.choice == choice && $0.scale == scale && $0.palette == palette && $0.width == width }) { return hit.value }
        let text = page.content?.text ?? ""
        let result = NSMutableAttributedString(string: "")
        if page.source || page.content?.renderer != .markdown {
            result.append(NSAttributedString(string: text.replacingOccurrences(of: "\t", with: "    "), attributes: attributes(role: .body, choice: choice, scale: scale, palette: palette)))
        } else {
            let segments = ZeusMarkdown.documentSegments(text, choice: choice, palette: palette, scale: scale)
            for (index, segment) in segments.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n\n", attributes: attributes(role: .body, choice: choice, scale: scale, palette: palette))) }
                switch segment {
                case .text(let attributed): result.append(native(attributed, choice: choice, scale: scale, palette: palette))
                case .image(let path, let alt):
                    if let url = DocumentLoader.localImage(path, document: page.url),
                       let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 {
                        let factor = min(1, max(1, width - 28) / image.size.width, 320 / image.size.height)
                        let attachment = NSTextAttachment()
                        attachment.image = image
                        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * factor, height: image.size.height * factor)
                        result.append(NSAttributedString(attachment: attachment))
                        result.append(NSAttributedString(string: "\n" + alt, attributes: attributes(role: .caption, choice: choice, scale: scale, palette: palette)))
                    } else {
                        var attrs = attributes(role: .body, choice: choice, scale: scale, palette: palette)
                        attrs[.foregroundColor] = NSColor(palette.secondaryText)
                        result.append(NSAttributedString(string: "[image: \(alt)]", attributes: attrs))
                    }
                }
            }
        }
        if page.content?.renderer == .markdown {
            markAnchors(in: result, source: page.source)
            if page.source { markSourceLinks(in: result) }
        }
        let value = NSAttributedString(attributedString: result)
        cache.append(.init(id: page.id, revision: revision, source: page.source, choice: choice, scale: scale, palette: palette, width: width, value: value))
        if cache.count > 4 { cache.removeFirst(cache.count - 4) }
        return value
    }
    static func native(_ text: AttributedString, choice: ZeusFontChoice, scale: ZeusFontScale, palette: ZeusPalette) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let heading = run[ZeusMarkdown.HeadingLevelAttribute.self]
            var attrs = attributes(role: heading == 1 ? .title : .body, choice: choice, scale: scale, palette: palette)
            if let heading { attrs[headingKey] = heading }
            if let color = run.foregroundColor { attrs[.foregroundColor] = NSColor(color) }
            if let color = run.backgroundColor { attrs[.backgroundColor] = NSColor(color) }
            if let link = run.link { attrs[.link] = link; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if choice == .system, run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true, let font = attrs[.font] as? NSFont {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if choice == .system, run.inlinePresentationIntent?.contains(.emphasized) == true, let font = attrs[.font] as? NSFont {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attrs))
        }
        return result
    }
    /// Slugs are assigned in document order, including collisions with an explicit numbered heading.
    private static func markAnchors(in text: NSMutableAttributedString, source: Bool) {
        let string = text.string as NSString
        var used: Set<String> = []
        var start = 0
        var fence: String?
        while start < string.length {
            let range = string.lineRange(for: NSRange(location: start, length: 0))
            let line = string.substring(with: range).trimmingCharacters(in: .newlines)
            var heading: String?
            if source {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let marker = String(trimmed.prefix(3))
                    if fence == marker { fence = nil } else if fence == nil { fence = marker }
                } else if fence == nil {
                    if let match = line.range(of: #"^ {0,3}#{1,6}[ \t]+"#, options: .regularExpression) {
                        heading = String(line[match.upperBound...]).replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                    } else if NSMaxRange(range) < string.length, !trimmed.isEmpty {
                        let next = string.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
                        let underline = string.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines)
                        if underline.range(of: #"^(=+|-+)$"#, options: .regularExpression) != nil { heading = line }
                    }
                }
                if let value = heading { heading = ZeusMarkdown.spokenText(markdown: value) }
            } else if text.attribute(headingKey, at: range.location, effectiveRange: nil) != nil {
                heading = line
            }
            if let heading {
                let base = heading.lowercased().filter { character in
                    character == "-" || !character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
                }.replacingOccurrences(of: " ", with: "-")
                var slug = base; var suffix = 0
                while used.contains(slug) { suffix += 1; slug = "\(base)-\(suffix)" }
                used.insert(slug)
                text.addAttribute(anchorKey, value: slug, range: range)
            }
            start = NSMaxRange(range)
        }
    }
    private static func markSourceLinks(in text: NSMutableAttributedString) {
        guard let pattern = try? NSRegularExpression(pattern: #"\[[^\]\n]+\]\(([^\s)]+)(?:\s+[^)]*)?\)"#) else { return }
        for match in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
            let reference = (text.string as NSString).substring(with: match.range(at: 1))
            if let url = URL(string: reference) { text.addAttribute(.link, value: url, range: match.range) }
        }
    }
    private static func attributes(role: ZeusTextRole, choice: ZeusFontChoice, scale: ZeusFontScale, palette: ZeusPalette) -> [NSAttributedString.Key: Any] {
        let size = role.size(for: choice, scale: scale)
        let font = choice == .pixel ? NSFont(name: ZeusFonts.pixelFamily, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor(palette.text), .paragraphStyle: paragraph, .ligature: 0]
    }
}
