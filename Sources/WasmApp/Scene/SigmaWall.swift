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
    // playable column above the floor and keep the proportional width.
    static let wallSize = CGSize(width: 24, height: 196)
    static let riseDuration: TimeInterval = 1.8
    // Godot SigmaWall.gd on_desperation: explode timer 1.65, end_explosion 2.0,
    // blink interval 0.032, explode-sound interval 0.17.
    static let explodeDelay: TimeInterval = 1.65
    static let cleanupDelay: TimeInterval = 2.0
    static let blinkInterval: TimeInterval = 0.032
    // Godot smoke.amount = 11 over lifetime 0.75s ≈ 14/sec. Match that for the
    // rise smoke spawn cadence.
    static let smokeInterval: TimeInterval = 0.07

    /// Side of the arena this wall guards. -1 = left wall (blocks leftward
    /// motion from inside), +1 = right wall. Matches Godot SigmaWall.tscn
    /// `direction` exports for the two pillar instances.
    let direction: Int
    private(set) var state: State = .hidden

    // The Godot port uses `region_rect.position.y` (-289 → 0 over 1.8s) to
    // reveal the wall WITHOUT stretching its texture. yScale would compress
    // the 258-tall image into a shorter quad, which distorts the cap and
    // shaft proportions. The SpriteKit equivalent is to slide a full-size
    // sprite UP through a fixed-position SKCropNode mask: the sprite emerges
    // from below the floor at true pixel scale, with the cap reaching higher
    // each frame as more of the shaft fills in beneath it.
    private let cropContainer: SKCropNode
    private let sprite: SKSpriteNode
    private let mask: SKSpriteNode
    private var riseTimer: TimeInterval = 0
    private var explodeTimer: TimeInterval = 0
    private var blinkTimer: TimeInterval = 0
    private var smokeTimer: TimeInterval = 0
    private var didExplode: Bool = false
    private var lastEasedProgress: CGFloat = 0

    /// AABB the scene physics step uses to push the player back. nil while
    /// hidden (intro pre-stage-4) or destroyed (post-desperation explosion).
    var hitbox: CGRect? {
        switch state {
        case .hidden, .destroyed:
            return nil
        case .rising:
            let halfW = Self.wallSize.width / 2
            let visibleHeight = Self.wallSize.height * lastEasedProgress
            return CGRect(
                x: position.x - halfW,
                y: position.y,
                width: Self.wallSize.width,
                height: visibleHeight
            )
        case .standing, .exploding:
            let halfW = Self.wallSize.width / 2
            return CGRect(
                x: position.x - halfW,
                y: position.y,
                width: Self.wallSize.width,
                height: Self.wallSize.height
            )
        }
    }

    init(direction: Int) {
        self.direction = direction
        let placeholderColor = SKColor(red: 0.45, green: 0.18, blue: 0.55, alpha: 1.0)
        sprite = SKSpriteNode(color: placeholderColor, size: Self.wallSize)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.colorBlendFactor = 1.0
        // Initial position: entirely below the mask (sprite top edge AT floor).
        sprite.position = CGPoint(x: 0, y: -Self.wallSize.height)
        sprite.alpha = 1.0

        // Mask defines the visible window: a fixed rectangle at floor level
        // matching the wall's footprint. Sprite content is only drawn where
        // the mask has alpha > 0.
        mask = SKSpriteNode(color: .white, size: Self.wallSize)
        mask.anchorPoint = CGPoint(x: 0.5, y: 0)
        mask.position = .zero

        cropContainer = SKCropNode()
        cropContainer.maskNode = mask
        cropContainer.addChild(sprite)

        super.init()
        addChild(cropContainer)
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
        smokeTimer = 0
        sprite.removeAllActions()
        sprite.position = CGPoint(x: 0, y: -Self.wallSize.height)
        sprite.alpha = 1.0
        lastEasedProgress = 0
        // Godot smoke.emitting = true on activate(); first puff fires immediately.
        spawnRiseSmoke()
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
        didExplode = false
        // Godot: explosions.emitting = true + end_smoke.emitting = true. Both
        // run until end_explosion_vfx() at 2.0s. The helpers self-remove
        // after `cleanupDelay`, so the scene doesn't have to track them.
        if let scene = scene {
            // explosions GPUParticles2D in Godot at offset (14, -100); flip Y
            // for SpriteKit Y-up so the cluster sits above the wall midline.
            let pulseAnchor = CGPoint(
                x: position.x + 14,
                y: position.y + 100
            )
            scene.addChild(BossEffects.sigmaWallExplosionPulse(at: pulseAnchor, duration: Self.cleanupDelay))
            // end_smoke at Godot offset (10, -147); Y-up flip places it near
            // the wall cap. Godot stops end_smoke inside `explode()` at 1.65s
            // (not at end_explosion_vfx at 2.0s), so pass `explodeDelay`.
            let smokeAnchor = CGPoint(
                x: position.x + 10,
                y: position.y + 147
            )
            scene.addChild(BossEffects.sigmaWallEndSmoke(at: smokeAnchor, duration: Self.explodeDelay))
        }
    }

    /// Reset to fresh-spawn state. Called by BossBattleScene.resetBattle so a
    /// retry replays the intro with both walls hidden again.
    func reset() {
        state = .hidden
        riseTimer = 0
        explodeTimer = 0
        blinkTimer = 0
        smokeTimer = 0
        didExplode = false
        sprite.removeAllActions()
        sprite.position = CGPoint(x: 0, y: -Self.wallSize.height)
        sprite.alpha = 1.0
        sprite.isHidden = false
        cropContainer.isHidden = false
        lastEasedProgress = 0
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
            lastEasedProgress = CGFloat(eased)
            // Slide the sprite up so its top edge tracks the visible cap
            // height. At progress=0 the sprite is fully below the mask
            // (invisible); at progress=1 it sits exactly inside the mask.
            sprite.position.y = -Self.wallSize.height * (1 - lastEasedProgress)
            // Continuous smoke spawn during rise — mirrors Godot smoke
            // GPUParticles2D emitting=true between activate() and the
            // tween-completion stop_smoke() callback.
            smokeTimer += dt
            while smokeTimer >= Self.smokeInterval {
                smokeTimer -= Self.smokeInterval
                spawnRiseSmoke()
            }
            if riseTimer >= Self.riseDuration {
                sprite.position.y = 0
                lastEasedProgress = 1
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
            if !didExplode && explodeTimer >= Self.explodeDelay {
                didExplode = true
                // Godot explode(): smoke off, end_smoke off (we let end_smoke
                // continue to its full duration since it's only ~0.35s away
                // from end_explosion_vfx anyway), remains burst, sprite
                // visibility off.
                if let scene = scene {
                    let burstAnchor = CGPoint(
                        x: position.x,
                        y: position.y + Self.wallSize.height / 2
                    )
                    scene.addChild(BossEffects.sigmaWallRemainsBurst(at: burstAnchor))
                }
                sprite.alpha = 1
                cropContainer.isHidden = true
            }
            if explodeTimer >= Self.cleanupDelay {
                state = .destroyed
            }
        }
    }

    // MARK: - Helpers

    private func spawnRiseSmoke() {
        guard let scene = scene else { return }
        let puff = BossEffects.sigmaWallRiseSmoke(at: position)
        scene.addChild(puff)
    }
}
