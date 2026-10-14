import CoreGraphics
import Foundation
import Testing
import ZeusProtocol
@testable import ZeusSprites

/// Q2 DES-17 / DES-19: emotes across the roster, as the app places them.
struct EmoteLayoutTests {
    /// Opaque-pixel bounds of an image, top-left origin, in canvas pixels.
    static func bounds(_ image: CGImage, differingFrom other: CGImage? = nil) -> CGRect? {
        func bytes(_ i: CGImage) -> [UInt8] { [UInt8]((i.dataProvider?.data as Data?) ?? Data()) }
        let a = bytes(image), b = other.map(bytes)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = y * image.bytesPerRow + x * 4
                let hit: Bool = if let b { a[i..<i + 4] != b[i..<i + 4] } else { a[i + 3] > 0 }
                if hit { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static var characters: [SpriteCharacter] { CharacterLibrary.load(userDirectory: nil).characters }

    static func emoteRect(_ c: SpriteCharacter, _ state: AvatarState) -> CGRect? {
        let still = RenderOptions(showEmote: false, reduceMotion: true)
        let with = RenderOptions(showEmote: true, reduceMotion: true)
        return bounds(SpriteRenderer.render(c, state: state, time: 0, options: with),
                      differingFrom: SpriteRenderer.render(c, state: state, time: 0, options: still))
    }

    /// The app's warning marker (AvatarArtRect.warningTopLeft): 18 × 18 pt at the idle art's top-left, 4 pt out.
    static func markerRect(_ c: SpriteCharacter, scale: Int) -> CGRect? {
        guard let art = bounds(SpriteRenderer.render(c, state: .idle, time: 0, options: .init(showEmote: false, reduceMotion: true)))
        else { return nil }
        let s = CGFloat(scale)
        return CGRect(x: art.minX * s - 4, y: art.minY * s - 4, width: 18, height: 18)
    }

    /// The app's unread badge (AvatarArtRect.badgeCorner): trailing edge 4 pt right of the art, top 4 pt above it.
    /// "9+" is about 26 × 18 pt.
    static func badgeRect(_ c: SpriteCharacter, scale: Int) -> CGRect? {
        guard let art = bounds(SpriteRenderer.render(c, state: .idle, time: 0, options: .init(showEmote: false, reduceMotion: true)))
        else { return nil }
        let s = CGFloat(scale)
        return CGRect(x: art.maxX * s + 4 - 26, y: art.minY * s - 4, width: 26, height: 18)
    }

    @Test func theWarningMarkerAndBadgeNeverCoverTheAlertEmote() throws {
        for c in Self.characters {
            let emote = try #require(Self.emoteRect(c, .alert), "\(c.id) has no alert emote")
            for multiplier in [0.75, 1, 1.25] {
                let scale = max(2, Int((Double(c.preferredScale) * multiplier).rounded()))
                let marker = try #require(Self.markerRect(c, scale: scale))
                let onScreen = CGRect(x: emote.minX * CGFloat(scale), y: emote.minY * CGFloat(scale),
                                      width: emote.width * CGFloat(scale), height: emote.height * CGFloat(scale))
                #expect(!onScreen.intersects(marker), "\(c.id) at scale \(scale): emote \(onScreen) vs marker \(marker)")
                let badge = try #require(Self.badgeRect(c, scale: scale))
                #expect(!onScreen.intersects(badge), "\(c.id) at scale \(scale): emote \(onScreen) vs badge \(badge)")
            }
        }
    }

    @Test func emotesAreAboutTheSameSizeOnScreenAcrossTheRoster() throws {
        var heights: [String: CGFloat] = [:]
        for c in Self.characters {
            let emote = try #require(Self.emoteRect(c, .alert))
            heights[c.id] = emote.height * CGFloat(c.preferredScale)
        }
        let low = heights.values.min() ?? 0, high = heights.values.max() ?? 0
        print("[emote heights pt] \(heights.sorted { $0.key < $1.key })")
        #expect(high / low <= 1.4, "\(heights)")
    }
}

extension EmoteLayoutTests {
    /// DES-19: every character's outline ring or the ring just inside it averages at least 2:1 against a dark
    /// desktop (#1E1E1E), so no avatar disappears on a dark wallpaper.
    @Test func silhouettesReadOnADarkDesktop() throws {
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let backdrop = luminance(0x1E / 255, 0x1E / 255, 0x1E / 255)
        var results: [String: Double] = [:]
        for c in Self.characters {
            let image = SpriteRenderer.render(c, state: .idle, time: 0, options: .init(showEmote: false, reduceMotion: true))
            let bytes = [UInt8]((image.dataProvider?.data as Data?) ?? Data())
            func alpha(_ x: Int, _ y: Int) -> UInt8 {
                guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
                return bytes[y * image.bytesPerRow + x * 4 + 3]
            }
            // Ring 1 is the outline (touching transparency); ring 2 is the pixel inside it. A silhouette reads
            // when either ring stands out: a light rim, or a dark outline around a light body.
            var totals = [0.0, 0.0], counts = [0, 0]
            func touches(_ x: Int, _ y: Int, _ r: Int) -> Bool {
                (-r...r).contains { dy in (-r...r).contains { dx in alpha(x + dx, y + dy) == 0 } }
            }
            for y in 0..<image.height {
                for x in 0..<image.width where alpha(x, y) == 255 {
                    let ring = touches(x, y, 1) ? 0 : touches(x, y, 2) ? 1 : -1
                    guard ring >= 0 else { continue }
                    let i = y * image.bytesPerRow + x * 4
                    let l = luminance(Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
                    totals[ring] += (max(l, backdrop) + 0.05) / (min(l, backdrop) + 0.05)
                    counts[ring] += 1
                }
            }
            results[c.id] = zip(totals, counts).map { $1 == 0 ? 0 : $0 / Double($1) }.max() ?? 0
        }
        print("[silhouette contrast vs dark desktop] \(results.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" })")
        for (id, value) in results { #expect(value >= 2.0, "\(id): \(value)") }
    }
}
