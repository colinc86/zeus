import SwiftUI
import Foundation

/// A rectangle whose corners are cut in stair steps of one UI pixel, like a retro dialog box.
public struct PixelRoundedRectangle: InsettableShape {
    /// Size of one stair step, in points.
    public var step: CGFloat
    /// Number of steps per corner (0 = square).
    public var steps: Int
    var inset: CGFloat = 0

    public init(step: CGFloat = ZeusTheme.pixel, steps: Int = ZeusTheme.cornerSteps) {
        self.step = step
        self.steps = steps
    }

    public func inset(by amount: CGFloat) -> PixelRoundedRectangle {
        var copy = self
        copy.inset += amount
        return copy
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let n = max(0, min(steps, Int(min(r.width, r.height) / (2 * step))))
        var p = Path()
        // Walk clockwise from the top edge, stepping each corner.
        p.move(to: CGPoint(x: r.minX + CGFloat(n) * step, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - CGFloat(n) * step, y: r.minY))
        for i in 0..<n {  // top-right
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(n - i) * step, y: r.minY + CGFloat(i + 1) * step))
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(n - i - 1) * step, y: r.minY + CGFloat(i + 1) * step))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - CGFloat(n) * step))
        for i in 0..<n {  // bottom-right
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(i + 1) * step, y: r.maxY - CGFloat(n - i) * step))
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(i + 1) * step, y: r.maxY - CGFloat(n - i - 1) * step))
        }
        p.addLine(to: CGPoint(x: r.minX + CGFloat(n) * step, y: r.maxY))
        for i in 0..<n {  // bottom-left
            p.addLine(to: CGPoint(x: r.minX + CGFloat(n - i) * step, y: r.maxY - CGFloat(i + 1) * step))
            p.addLine(to: CGPoint(x: r.minX + CGFloat(n - i - 1) * step, y: r.maxY - CGFloat(i + 1) * step))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + CGFloat(n) * step))
        for i in 0..<n {  // top-left
            p.addLine(to: CGPoint(x: r.minX + CGFloat(i + 1) * step, y: r.minY + CGFloat(n - i) * step))
            p.addLine(to: CGPoint(x: r.minX + CGFloat(i + 1) * step, y: r.minY + CGFloat(n - i - 1) * step))
        }
        p.closeSubpath()
        return p
    }
}

/// Paints the standard Zeus frame: a dark outline, a light frame, then the fill.
struct PixelFrame: View {
    var outline: Color
    var frame: Color?
    var fill: Color
    var steps = ZeusTheme.cornerSteps

    var body: some View {
        let shape = PixelRoundedRectangle(steps: steps)
        if ZeusScrollExperiment.singleFrame {
            // One SwiftUI drawing node, with the exact original paths and paint order.
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(shape.path(in: rect), with: .color(outline))
                if let frame {
                    context.fill(shape.inset(by: ZeusTheme.pixel).path(in: rect), with: .color(frame))
                    context.fill(shape.inset(by: ZeusTheme.pixel * 2).path(in: rect), with: .color(fill))
                } else {
                    context.fill(shape.inset(by: ZeusTheme.pixel).path(in: rect), with: .color(fill))
                }
            }
        } else {
            ZStack {
                shape.fill(outline)
                if let frame {
                    shape.inset(by: ZeusTheme.pixel).fill(frame)
                    shape.inset(by: ZeusTheme.pixel * 2).fill(fill)
                } else {
                    shape.inset(by: ZeusTheme.pixel).fill(fill)
                }
            }
        }
    }
}

/// Where a dialog's tail points: the edge it sticks out of, and where the tip sits along that edge.
/// For `.top`/`.bottom`, `offset` is the tip's x from the panel's leading edge; for `.leading`/`.trailing`
/// (peek bubbles beside Zeus), it's the tip's y from the panel's top. The app sets it to the avatar's
/// anchor (CARDS.md §4, CONVERSATION.md §14).
public struct ZeusDialogTail: Sendable, Equatable {
    public enum Edge: Sendable, Equatable { case top, bottom, leading, trailing }
    public var edge: Edge
    public var offset: CGFloat

    public init(edge: Edge, offset: CGFloat) {
        self.edge = edge
        self.offset = offset
    }

    /// The tail's height, in points. Panels reserve this much space on the tail's edge.
    public static let height: CGFloat = ZeusTheme.pixel * 5
}

/// A stepped pixel triangle pointing down (flipped for `.top`), `rows` UI pixels tall.
struct PixelTailShape: Shape {
    var rows = 5
    var pointsUp = false

    func path(in rect: CGRect) -> Path {
        let px = rect.height / CGFloat(rows)
        var p = Path()
        for row in 0..<rows {
            let half = CGFloat(rows - row) * px
            let y = pointsUp ? rect.maxY - CGFloat(row + 1) * px : rect.minY + CGFloat(row) * px
            p.addRect(CGRect(x: rect.midX - half, y: y, width: half * 2, height: px))
        }
        return p
    }
}

/// Small pixel-drawn symbols for UI that Departure Mono has no glyph for (✓ ✕ ↩ ◀ ▶ ↑), so they sit on the
/// same grid as the text instead of falling back to a vector font (Q2 DES-4). One glyph pixel is one point:
/// Departure Mono's font pixel at 11 pt. Fills with the foreground style, like text.
public struct ZeusGlyph: View {
    public enum Symbol: String, CaseIterable, Sendable {
        case check, close, reply, left, right, up
        /// The rating affordance (⋯) (FB1, CONVERSATION.md §17): the font has no ellipsis on its grid.
        case more

        /// Rows of the bitmap, top to bottom; "#" is filled. All are 7 px tall, the font's cap height.
        public var rows: [String] {
            switch self {
            case .check: [".....##", "....##.", "#..##..", "##.##..", ".###...", "..#....", "......."]
            case .close: ["#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#"]
            case .reply: ["......#", "......#", "..#...#", ".##...#", "#######", ".##....", "..#...."]
            case .left: ["...#", "..##", ".###", "####", ".###", "..##", "...#"]
            case .right: ["#...", "##..", "###.", "####", "###.", "##..", "#..."]
            case .up: ["...##...", "..####..", ".######.", "###..###", "...##...", "...##...", "...##..."]
            case .more: ["..........", "..........", "..........", "##..##..##", "##..##..##", "..........", ".........."]
            }
        }
        /// What VoiceOver should say when the glyph stands alone.
        public var spokenName: String {
            switch self {
            case .check: "checked"
            case .close: "close"
            case .reply: "reply"
            case .left: "previous"
            case .right: "next"
            case .up: "send"
            case .more: "rate"
            }
        }
    }

    public var symbol: Symbol
    public var pixel: CGFloat

    public init(_ symbol: Symbol, pixel: CGFloat = 1) {
        self.symbol = symbol
        self.pixel = pixel
    }

    public var body: some View {
        let rows = symbol.rows
        let width = CGFloat(rows.map(\.count).max() ?? 0) * pixel
        GlyphShape(rows: rows, pixel: pixel)
            .frame(width: width, height: CGFloat(rows.count) * pixel)
            .accessibilityHidden(true)
    }

    struct GlyphShape: Shape {
        let rows: [String]
        let pixel: CGFloat
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    path.addRect(CGRect(x: rect.minX + CGFloat(x) * pixel, y: rect.minY + CGFloat(y) * pixel, width: pixel, height: pixel))
                }
            }
            return path
        }
    }
}

/// Temporary S1c measurement switches. Ordinary builds and non-isolated launches retain the design.
enum ZeusScrollExperiment {
    #if os(macOS) && (DEBUG || ZEUS_PERFORMANCE_PROBE)
    private static let isolated = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
        && ProcessInfo.processInfo.environment["ZEUS_PERF_SCROLL"] == "1"
    static let opaquePanel = isolated && ProcessInfo.processInfo.environment["ZEUS_PERF_OPAQUE_PANEL"] == "1"
    static let singleFrame = isolated && ProcessInfo.processInfo.environment["ZEUS_PERF_SINGLE_FRAME"] == "1"
    #else
    static let opaquePanel = false
    static let singleFrame = false
    #endif
}
