import Foundation
import OpenSpriteKit

// MARK: - SigmaWall
// Vertical pillar that rises from below the floor at intro stage 4 and
// constrains the player toward the centre of the arena. On Sigma's
// desperation (OverdriveAttack firing edge) the wall on the matching side
// blinks then explodes, freeing that edge for the rest of the fight.
//
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/SigmaWall.gd +
// SigmaWall.tscn (sigma_wall.png 32x258 sprite, 31x288 collision).

@MainActor
final class SigmaWall: SKNode {
    enum State {
        case hidden
        case rising
        case standing
        case exploding
        case destroyed
    }

    // Godot sprite is 32x258, region scrolls from y=-289 (hidden below floor)
    // to y=0 (fully visible) over 1.8s with EaseOut/TransCirc. Our 224-tall
    // arena can't fit 258px on screen — clamp the visible height to the
    // playable column above the floor and keep the same width.
    static let wallSize = CGSize(width: 24, height: 196)
    static let riseDuration: TimeInterval = 1.8
    // Godot SigmaWall.gd on_desperation: explode timer 1.65, end_explosion 2.0,
    // blink interval 0.032, explode-sound interval 0.17.
    static let explodeDelay: TimeInterval = 1.65
    static let cleanupDelay: TimeInterval = 2.0
    static let blinkInterval: TimeInterval = 0.032

    /// Side of the arena this wall guards. -1 = left wall (blocks leftward
    /// motion from inside), +1 = right wall. Matches Godot SigmaWall.tscn
    /// `direction` exports for the two pillar instances.
    let direction: Int
    private(set) var state: State = .hidden

    private let sprite: SKSpriteNode
    private var riseTimer: TimeInterval = 0
    private var explodeTimer: TimeInterval = 0
    private var blinkTimer: TimeInterval = 0

    /// AABB the scene physics step uses to push the player back. nil while
    /// hidden (intro pre-stage-4) or destroyed (post-desperation explosion).
    var hitbox: CGRect? {
        switch state {
        case .hidden, .destroyed:
            return nil
        case .rising, .standing, .exploding:
            let halfW = Self.wallSize.width / 2
            let visibleHeight = Self.wallSize.height * sprite.yScale
            return CGRect(
                x: position.x - halfW,
                y: position.y,
                width: Self.wallSize.width,
                height: visibleHeight
            )
        }
    }

    init(direction: Int) {
        self.direction = direction
        let placeholderColor = SKColor(red: 0.45, green: 0.18, blue: 0.55, alpha: 1.0)
        sprite = SKSpriteNode(color: placeholderColor, size: Self.wallSize)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.colorBlendFactor = 1.0
        sprite.position = .zero
        sprite.yScale = 0
        sprite.alpha = 1.0
        super.init()
        addChild(sprite)
        zPosition = 35
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Bind the Aseprite-grid-loaded sigma_wall texture once the loader has
    /// fetched it. Called once at boot — safe before or after `activate()`.
    func attachTexture(_ texture: SKTexture) {
        sprite.texture = texture
        sprite.colorBlendFactor = 0
        sprite.size = Self.wallSize
    }

    // MARK: - Lifecycle

    /// Mirrors Godot SigmaWall.gd `activate()`: arms the rise tween, enables
    /// the collider. Idempotent — calling on a rising/standing wall is a no-op
    /// so SigmaIntro can fire the signal repeatedly without resetting state.
    func activate() {
        guard state == .hidden else { return }
        state = .rising
        riseTimer = 0
        sprite.removeAllActions()
        sprite.yScale = 0
        sprite.alpha = 1.0
    }

    /// Mirrors Godot SigmaWall.gd `on_desperation(attack_direction)`. Only the
    /// wall whose `direction` matches the attack direction explodes — the
    /// other wall keeps its collider for the duration of the fight. Wraps the
    /// blink loop, particle hand-wave, and post-1.65s cleanup into a single
    /// state transition.
    func onDesperation(attackDirection: Int) {
        guard state == .rising || state == .standing else { return }
        guard direction == attackDirection else { return }
        state = .exploding
        explodeTimer = 0
        blinkTimer = 0
    }

    /// Reset to fresh-spawn state. Called by BossBattleScene.resetBattle so a
    /// retry replays the intro with both walls hidden again.
    func reset() {
        state = .hidden
        riseTimer = 0
        explodeTimer = 0
        blinkTimer = 0
        sprite.removeAllActions()
        sprite.yScale = 0
        sprite.alpha = 1.0
        sprite.isHidden = false
    }

    // MARK: - Tick

    func tick(_ dt: TimeInterval) {
        switch state {
        case .hidden, .destroyed:
            return
        case .rising:
            riseTimer += dt
            let progress = min(1.0, riseTimer / Self.riseDuration)
            // Godot SigmaWall.gd uses EASE_OUT + TRANS_CIRC. Output curve:
            //   y(t) = sqrt(1 - (1 - t)^2)
            let inv = 1 - progress
            let eased = sqrt(max(0, 1 - inv * inv))
            sprite.yScale = CGFloat(eased)
            if riseTimer >= Self.riseDuration {
                sprite.yScale = 1.0
                state = .standing
            }
        case .standing:
            return
        case .exploding:
            explodeTimer += dt
            blinkTimer += dt
            if blinkTimer >= Self.blinkInterval {
                blinkTimer -= Self.blinkInterval
                sprite.alpha = sprite.alpha > 0.5 ? 0 : 1
            }
            if explodeTimer >= Self.explodeDelay {
                state = .destroyed
                sprite.alpha = 1.0
                sprite.isHidden = true
            }
        }
    }
}
