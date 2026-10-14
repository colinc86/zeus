import SwiftUI

// MARK: - Typing indicator

/// The thread's last row while an agent is producing a response (CONTRACT §10.8,
/// CONVERSATION.md §15): a compact agent-side bubble with three hopping pixel dots, an optional
/// one-line `detail`, and an optional thin progress bar.
///
/// Map `AssistantActivity` straight onto it:
/// ```swift
/// ZeusTypingIndicator(phase, agentName: activity.agentName, detail: activity.detail, progress: activity.progress)
/// ```
///
/// Cost: the dot cycle (0.2 s steps; 0.4 s for `.sent`) is a Core Animation keyframe animation, so it
/// runs in the render server. The SwiftUI body is only re-evaluated when `phase`, `detail`, `progress`
/// or the environment change, never per step (D16). While `\.zeusAnimationsActive` is false or Reduce
/// Motion is on, the animation is removed and the dots hold still.
public struct ZeusTypingIndicator: View {
    /// What the agent is doing. Mirrors `AssistantActivity.Phase`.
    public enum Phase: Sendable, Equatable, CaseIterable {
        /// Delivered; no sign of the agent yet. Subtle: dim dots that pulse slowly, no hop.
        case sent
        /// The agent has picked it up. Gold dots that hop in turn.
        case thinking
        /// The agent reported work in progress (`zeus_set_status`). Like `.thinking`; shows "Working…"
        /// when there's no `detail`.
        case working
    }

    public var phase: Phase
    public var agentName: String?
    public var detail: String?
    public var progress: Double?
    /// Draws the frame at this date, without a clock (galleries and render tests).
    var stillFrame: Date?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive

    /// - Parameters:
    ///   - agentName: used for VoiceOver ("Claude is thinking"); not drawn.
    ///   - detail: one line, truncated at the tail. Blank strings are ignored.
    ///   - progress: 0…1 draws a thin bar under the dots; `nil` draws none (the dots are the indeterminate state).
    public init(_ phase: Phase, agentName: String? = nil, detail: String? = nil, progress: Double? = nil) {
        self.phase = phase
        self.agentName = agentName
        self.detail = detail
        self.progress = progress
    }

    public var body: some View {
        let caption = Self.caption(phase: phase, detail: detail, agentName: agentName)
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs + ZeusTheme.pixel) {
            HStack(spacing: ZeusTheme.Spacing.s) {
                Group {
                    if let stillFrame {
                        dots(Self.dots(phase: phase, at: stillFrame), palette: palette)
                    } else if animationsActive && !reduceMotion {
                        TypingDotsLayerView(phase: phase, color: phase == .sent ? palette.secondaryText : palette.title)
                            .frame(width: Self.dotsWidth, height: Self.dotSize + Self.hop)
                    } else {
                        dots(Self.restingDots(phase: phase), palette: palette)
                    }
                }
                if let caption {
                    Text(caption).zeusFont(.caption).foregroundStyle(palette.secondaryText)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            if let progress {
                ZeusThinProgress(value: progress)
            }
        }
        .padding(.horizontal, ZeusTheme.Spacing.m)
        .padding(.vertical, ZeusTheme.Spacing.s)
        .frame(minWidth: progress == nil ? nil : Self.minWidthWithProgress, alignment: .leading)
        .background {
            // `.sent` recedes with a flat, panel-colored bubble rather than opacity, so its caption keeps AA.
            if phase == .sent {
                PixelFrame(outline: palette.fieldBorder, frame: nil, fill: palette.panel)
            } else {
                PixelFrame(outline: palette.outline, frame: palette.fieldBorder, fill: palette.agentBubble)
            }
        }
        .frame(maxWidth: ZeusTheme.Conversation.agentBubbleMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(phase: phase, agentName: agentName, detail: detail, progress: progress))
    }

    private func dots(_ states: [Dot], palette: ZeusPalette) -> some View {
        let color = phase == .sent ? palette.secondaryText : palette.title
        return HStack(alignment: .bottom, spacing: Self.dotGap) {
            ForEach(states.indices, id: \.self) { i in
                Rectangle().fill(color.opacity(states[i].lit ? 1 : Double(Self.dimOpacity)))
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .offset(y: states[i].lifted ? -Self.hop : 0)
            }
        }
        // Room for the hop, so the row never changes height.
        .frame(height: Self.dotSize + Self.hop, alignment: .bottom)
    }
}

extension ZeusTypingIndicator {
    /// One dot's look in a frame.
    struct Dot: Equatable {
        var lit: Bool
        var lifted: Bool
    }

    nonisolated static let dotSize: CGFloat = ZeusTheme.pixel * 3
    nonisolated static let dotGap: CGFloat = ZeusTheme.pixel * 2
    nonisolated static let hop: CGFloat = ZeusTheme.pixel * 2
    nonisolated static let dotsWidth: CGFloat = dotSize * 3 + dotGap * 2
    nonisolated static let minWidthWithProgress: CGFloat = 180
    /// Opacity of an unlit dot.
    nonisolated static let dimOpacity: Float = 0.4
    /// A fixed epoch, so remounting the row doesn't restart or jitter the cycle.
    nonisolated static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Seconds per frame: 0.2 s while the agent is on it (5 changes a second), 0.4 s while only sent.
    nonisolated static func interval(for phase: Phase) -> TimeInterval {
        phase == .sent ? 0.4 : 0.2
    }

    /// The frame index at `date` in a 4-step cycle: dot 0, dot 1, dot 2, rest.
    nonisolated static func step(phase: Phase, at date: Date) -> Int {
        let n = (date.timeIntervalSince(epoch) / interval(for: phase)).rounded(.down)
        return Int(n.truncatingRemainder(dividingBy: 4) + 4) % 4
    }

    /// The three dots at `date`. `.sent` brightens one dot at a time and never hops; the others hop
    /// the lit dot by one pixel. Step 3 is a beat of rest.
    nonisolated static func dots(phase: Phase, at date: Date) -> [Dot] {
        let step = step(phase: phase, at: date)
        return (0..<3).map { i in
            let active = i == step
            return Dot(lit: active, lifted: active && phase != .sent)
        }
    }

    /// The still frame (Reduce Motion, or the surface isn't visible): all lit, or all dim for `.sent`.
    nonisolated static func restingDots(phase: Phase) -> [Dot] {
        Array(repeating: Dot(lit: phase != .sent, lifted: false), count: 3)
    }

    /// The text beside the dots: the trimmed `detail`, else "Working…" for `.working`, else none.
    nonisolated static func caption(phase: Phase, detail: String?, agentName: String? = nil) -> String? {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            // One line: a multi-line detail shows its first line.
            return trimmed.split(whereSeparator: \.isNewline).first.map(String.init)
        }
        switch phase {
        case .working: return "Working…"
        // Words, so the dim dots don't read as a disabled button (Q2 DES-21).
        case .sent:
            let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "Sent" : "Sent to \(name)"
        case .thinking: return nil
        }
    }

    nonisolated static func accessibilityLabel(phase: Phase, agentName: String?, detail: String?, progress: Double?) -> String {
        let who = agentName.flatMap { $0.isEmpty ? nil : $0 } ?? "Assistant"
        var parts: [String]
        switch phase {
        case .sent: parts = ["Sent to \(who)"]
        case .thinking: parts = ["\(who) is thinking"]
        case .working: parts = ["\(who) is working"]
        }
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty { parts.append(detail) }
        if let progress, progress.isFinite {
            parts.append("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }
}

/// A 6 pt pixel progress bar for the typing row: a dark track and a fill that grows in whole
/// 2 pt pixels. Static; it only changes when `value` does.
struct ZeusThinProgress: View {
    var value: Double
    @Environment(\.zeusPalette) private var palette

    nonisolated static let height: CGFloat = ZeusTheme.pixel * 3

    /// The fill width for `value` in a track of `width`, snapped down to whole pixels.
    nonisolated static func fillWidth(value: Double, width: CGFloat) -> CGFloat {
        guard value.isFinite, width > 0 else { return 0 }
        let raw = CGFloat(min(max(value, 0), 1)) * width
        return (raw / ZeusTheme.pixel).rounded(.down) * ZeusTheme.pixel
    }

    var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            GeometryReader { geo in
                let inner = geo.size.width - ZeusTheme.pixel * 2
                ZStack(alignment: .leading) {
                    Rectangle().fill(palette.outline)
                    Rectangle().fill(palette.track).padding(ZeusTheme.pixel)
                    Rectangle().fill(palette.fill)
                        .frame(width: Self.fillWidth(value: value, width: inner))
                        .padding(ZeusTheme.pixel)
                }
            }
            .frame(height: Self.height)
            Text("\(Int((min(max(value.isFinite ? value : 0, 0), 1) * 100).rounded()))%")
                .zeusFont(.caption).monospacedDigit().foregroundStyle(palette.secondaryText)
        }
    }
}

extension ZeusTypingIndicator {
    init(_ phase: Phase, stillFrame: Date) {
        self.init(phase)
        self.stillFrame = stillFrame
    }
}

// MARK: - Gallery

/// Every typing-indicator variant in both appearances, with the bubble it sits under.
/// Used by the `#Preview` below and by `zeus-sprites typing` (docs/design/typing-d15.png).
public struct ZeusTypingGallery: View {
    /// Draws each animated variant at a fixed frame, for reproducible renders.
    var frozen: Bool

    public init(frozen: Bool = false) {
        self.frozen = frozen
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(.dark)
            column(.light)
        }
        .fixedSize()
    }

    private func column(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.l) {
            row("after you send · .sent (dim, slow pulse)") {
                ZeusBubble(.user) { Text("Can you draft my Q3 talk?") }
                ZeusTypingIndicator(.sent, agentName: "Claude")
            }
            row(".thinking · gold dots hop in turn") {
                ZeusTypingIndicator(.thinking, agentName: "Claude")
            }
            row(".working · detail from zeus_set_status") {
                ZeusTypingIndicator(.working, agentName: "Claude", detail: "Drafting your Q3 talk")
            }
            row(".working · detail + progress") {
                ZeusTypingIndicator(.working, agentName: "Claude", detail: "Reading planning notes", progress: 0.4)
            }
            row("one cycle, 0.2 s per frame (.sent: 0.4 s, no hop)") {
                HStack(spacing: ZeusTheme.Spacing.s) {
                    ForEach(0..<4, id: \.self) { k in
                        ZeusTypingIndicator(.thinking, stillFrame: Self.frameDate(k))
                    }
                }
                HStack(spacing: ZeusTheme.Spacing.s) {
                    ForEach(0..<4, id: \.self) { k in
                        ZeusTypingIndicator(.sent, stillFrame: Self.frameDate(k * 2))
                    }
                }
            }
            row(".working · long detail truncates, no detail → \"Working…\"") {
                ZeusTypingIndicator(.working, agentName: "Claude",
                                    detail: "Summarising the forty-two unread threads in your work inbox since Friday")
                ZeusTypingIndicator(.working, agentName: "Claude")
            }
        }
        .padding(ZeusTheme.Spacing.xl)
        .frame(width: ZeusTheme.Conversation.panelWidth + ZeusTheme.Spacing.xl * 2, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(scheme == .dark ? Color(hex: 0x3B4256) : Color(hex: 0xD9DEE8))
        .environment(\.colorScheme, scheme)
        .environment(\.zeusAnimationsActive, !frozen)
    }

    private static func frameDate(_ k: Int) -> Date {
        ZeusTypingIndicator.epoch.addingTimeInterval(Double(k) * 0.2 + 0.01)
    }

    private func row<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text(caption).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: ZeusTheme.Conversation.spacing) { content() }
        }
    }
}

#Preview("Typing indicator") {
    let _ = ZeusFonts.registerBundled()
    ZeusTypingGallery()
}
