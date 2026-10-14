import AppKit
import SwiftUI
import ZeusSprites

/// State changes configure the driver; frame ticks bypass the SwiftUI layout graph entirely.
struct PixelSpriteView: NSViewRepresentable {
    let character: SpriteCharacter
    let inputs: SpriteAnimationDriver.Inputs

    func makeNSView(context: Context) -> PixelSpriteLayerView { PixelSpriteLayerView() }
    func updateNSView(_ view: PixelSpriteLayerView, context: Context) {
        view.driver.configure(character: character, inputs: inputs)
    }
    static func dismantleNSView(_ view: PixelSpriteLayerView, coordinator: ()) { view.driver.pause() }
}

@MainActor
final class PixelSpriteLayerView: NSView {
    let driver: SpriteAnimationDriver

    init(driver: SpriteAnimationDriver = SpriteAnimationDriver()) {
        self.driver = driver
        super.init(frame: .zero)
        let pixels = CALayer()
        pixels.contentsGravity = .resize
        pixels.magnificationFilter = .nearest
        pixels.minificationFilter = .nearest
        layer = pixels
        wantsLayer = true
        driver.onImageChanged = { [weak self] image in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = image
            CATransaction.commit()
            #if DEBUG
            DebugSpriteFrameCounter.record(view: self, image: image)
            #endif
        }
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = driver.image }
    // Keep avatar gestures and gallery selection on their parent controls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { driver.pause() }
    }
}
