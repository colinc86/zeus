import Foundation
import CoreGraphics
import ZeusSprites
import ZeusProtocol

/// Owns the sprite clock outside SwiftUI; identical cached images never update the native layer.
@MainActor
final class SpriteAnimationDriver {
    struct Inputs: Equatable {
        let content: SpriteFrameSignature
        let state: AvatarState
        let options: RenderOptions
        var active: Bool
        init(character: SpriteCharacter, state: AvatarState, reduceMotion: Bool, active: Bool) {
            // Includes the file fingerprint, so a user character overriding an ID invalidates the cache.
            content = SpriteRenderer.signature(character, state: .idle, time: 0, options: .init(reduceMotion: true))
            self.state = state
            options = .init(reduceMotion: reduceMotion)
            self.active = active
        }
    }
    private(set) var image: CGImage?
    var onImageChanged: ((CGImage) -> Void)?
    private let cache = SpriteFrameCache()
    private var character: SpriteCharacter?
    private var inputs: Inputs?
    private var timer: Task<Void, Never>?
    private(set) var imageAssignments = 0
    private(set) var scheduledInterval: TimeInterval?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    func configure(character: SpriteCharacter, inputs: Inputs) {
        guard self.inputs != inputs else { return }
        pause()
        if self.inputs?.content != inputs.content { cache.removeAll() }
        self.character = character
        self.inputs = inputs
        // Retain the last frame while inactive, refreshing exactly once on resume.
        if inputs.active || image == nil { refresh() }
        guard inputs.active, let interval = SpriteRenderer.refreshInterval(character, state: inputs.state, options: inputs.options) else { return }
        scheduledInterval = interval
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard let character, let inputs, inputs.active || image == nil else { return }
        let next = cache.image(for: character, state: inputs.state,
                               time: clock().timeIntervalSinceReferenceDate, options: inputs.options)
        if next !== image {
            image = next
            imageAssignments += 1
            onImageChanged?(next)
        }
    }

    func pause() { timer?.cancel(); timer = nil; scheduledInterval = nil; inputs?.active = false }
    deinit { timer?.cancel() }
}
