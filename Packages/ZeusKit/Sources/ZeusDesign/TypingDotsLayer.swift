import QuartzCore
import SwiftUI

// D16: the typing indicator's dots, animated by Core Animation instead of a SwiftUI clock.
// A TimelineView step re-evaluated the row and invalidated the whole conversation panel 5×/s
// (≈ 8% app CPU). A repeating CAKeyframeAnimation is committed once and runs in the render
// server, so the app does no work per step.

/// Three dot sublayers with discrete, repeating keyframe animations that reproduce
/// `ZeusTypingIndicator.dots(phase:at:)` exactly, aligned to the same epoch.
final class TypingDotsLayer: CALayer {
    private var dotLayers: [CALayer] = []
    private var configured: (phase: ZeusTypingIndicator.Phase, color: CGColor)?
    /// Whether +y is up in this layer's geometry. Changing it restarts the animations.
    var yUp = false {
        didSet { if yUp != oldValue, let configured { self.configured = nil; configure(phase: configured.phase, color: configured.color) } }
    }

    override init() {
        super.init()
        for _ in 0..<3 {
            let dot = CALayer()
            dot.actions = ["position": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(), "bounds": NSNull()]
            addSublayer(dot)
            dotLayers.append(dot)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The resting position of dot `i` (bottom of the layer, hop room above).
    private func basePosition(_ i: Int) -> CGPoint {
        let size = ZeusTypingIndicator.dotSize
        let x = CGFloat(i) * (size + ZeusTypingIndicator.dotGap) + size / 2
        let y = yUp ? size / 2 : ZeusTypingIndicator.hop + size / 2
        return CGPoint(x: x, y: y)
    }

    /// Applies the phase and color, (re)starting the animations only when either changed.
    func configure(phase: ZeusTypingIndicator.Phase, color: CGColor) {
        if let configured, configured.phase == phase, configured.color == color { return }
        configured = (phase, color)
        let size = ZeusTypingIndicator.dotSize
        let cycle = ZeusTypingIndicator.interval(for: phase) * 4
        // Start the cycle in the past so step k lines up with the shared epoch.
        let elapsed = Date().timeIntervalSince(ZeusTypingIndicator.epoch).truncatingRemainder(dividingBy: cycle)
        let begin = convertTime(CACurrentMediaTime(), from: nil) - elapsed
        for (i, dot) in dotLayers.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.position = basePosition(i)
            dot.backgroundColor = color
            dot.opacity = ZeusTypingIndicator.dimOpacity
            dot.removeAllAnimations()
            // Four discrete steps: dot 0 lit, dot 1 lit, dot 2 lit, rest. In discrete mode keyTimes has
            // one more entry than values: value k holds from keyTimes[k] to keyTimes[k + 1].
            let keyTimes: [NSNumber] = [0, 0.25, 0.5, 0.75, 1]
            let lit = Self.litSteps(dot: i, phase: phase)
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = lit.map { $0 ? Float(1) : ZeusTypingIndicator.dimOpacity }
            let animations: [CAAnimation]
            if phase == .sent {
                animations = [opacity]
            } else {
                let lift = yUp ? ZeusTypingIndicator.hop : -ZeusTypingIndicator.hop
                let hop = CAKeyframeAnimation(keyPath: "position.y")
                hop.values = Self.liftedSteps(dot: i, phase: phase).map { basePosition(i).y + ($0 ? lift : 0) }
                animations = [opacity, hop]
            }
            for animation in animations {
                guard let keyframe = animation as? CAKeyframeAnimation else { continue }
                keyframe.calculationMode = .discrete
                keyframe.keyTimes = keyTimes
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = cycle
            group.repeatCount = .infinity
            group.beginTime = begin
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: "typing")
        }
    }

    /// Dot `i`'s lit state at each of the 4 steps (mirrors `ZeusTypingIndicator.dots(phase:at:)`).
    static func litSteps(dot i: Int, phase: ZeusTypingIndicator.Phase) -> [Bool] {
        (0..<4).map { $0 == i }
    }

    /// Dot `i`'s lifted state at each of the 4 steps.
    static func liftedSteps(dot i: Int, phase: ZeusTypingIndicator.Phase) -> [Bool] {
        (0..<4).map { $0 == i && phase != .sent }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Hosts `TypingDotsLayer` (layer-hosting, so AppKit never redraws it).
struct TypingDotsLayerView: NSViewRepresentable {
    var phase: ZeusTypingIndicator.Phase
    var color: Color

    final class DotsView: NSView {
        let dots = TypingDotsLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = dots
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Which way is up depends on the flips above this layer (NSHostingView is flipped), so
        /// read it from Core Animation once the layer is in the tree.
        override func layout() {
            super.layout()
            dots.yUp = !dots.contentsAreFlipped()
        }
    }

    func makeNSView(context: Context) -> DotsView {
        DotsView()
    }

    func updateNSView(_ view: DotsView, context: Context) {
        view.dots.configure(phase: phase, color: color.resolve(in: context.environment).cgColor)
    }
}
#elseif canImport(UIKit)
import UIKit

/// Hosts `TypingDotsLayer` as a UIView's backing layer.
struct TypingDotsLayerView: UIViewRepresentable {
    var phase: ZeusTypingIndicator.Phase
    var color: Color

    final class DotsView: UIView {
        override class var layerClass: AnyClass { TypingDotsLayer.self }
    }

    func makeUIView(context: Context) -> DotsView {
        let view = DotsView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: DotsView, context: Context) {
        (view.layer as? TypingDotsLayer)?.configure(phase: phase, color: color.resolve(in: context.environment).cgColor)
    }
}
#endif
