import Foundation
import OpenSpriteKit

// MARK: - Boss (Satan Sigma)
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/Sigma.tscn + BossAI.gd

@MainActor
final class Boss: Actor {
    // Logical hitbox is 40x56. Source frames in satan_sigma.json are 398x192
    // full-canvas (the character is drawn near the horizontal centre of each
    // frame with transparent padding). We render the full frame centred on the
    // boss node so the animation matches the reference sheet 1:1.
    static let bodySize = CGSize(width: 40, height: 56)
    static let spriteSize = CGSize(width: 398, height: 192)
    // The idle frame's bottom-most opaque pixel sits 32px above the frame's
    // bottom edge. Shift the visual down so Sigma's feet sit on the floor
    // rather than floating on the frame padding.
    static let spriteFootOffset: CGFloat = -32

    // Cannon mouth offset above the boss's feet. Mirrors Godot Sigma.tscn
    // SigmaLaser anchor `(27, 11)` Y-down relative to animatedSprite center,
    // mapped onto the megaman sprite layout (visual is 398×192, anchor at
    // (0.5, 0), positioned (0, spriteFootOffset)). Cannon sprite-pixel
    // (172, 107) from top-left in the unflipped LEFT-facing atlas → boss-local
    // (facing.sign * 27, 53). Used by OverdriveAttack to anchor the laser
    // and the windup ring at the cannon mouth.
    static let muzzleOffsetX: CGFloat = 27
    static let muzzleOffsetY: CGFloat = 53

    var activeAttack: Attack?
    private(set) var isStunned: Bool = false
    private var stunTimer: TimeInterval = 0

    private let visual: SKSpriteNode
    private var atlas: SpriteAtlas?
    private var currentAnimationTag: String?
    override var damageInvulnerabilityDuration: TimeInterval {
        PhysicsConstants.bossNormalInvulnerabilityDuration
    }

    init() {
        visual = SKSpriteNode(
            color: SKColor(red: 0.55, green: 0.15, blue: 0.25, alpha: 1.0),
            size: Self.spriteSize
        )
        visual.anchorPoint = CGPoint(x: 0.5, y: 0)
        visual.position = CGPoint(x: 0, y: Self.spriteFootOffset)
        visual.zPosition = 0.1
        visual.colorBlendFactor = 1.0
        // The satan_sigma atlas draws Sigma facing LEFT in its raw frames.
        // Godot's Sigma.tscn sets `animatedSprite.flip_h = true` so that the
        // baseline orientation is RIGHT, then the parent's scale flips to face
        // the player. Mirror that convention by pre-flipping the visual child.
        visual.xScale = -1

        // Boss node's own quad is invisible — visuals come from `visual`.
        super.init(
            color: .clear,
            size: Self.bodySize,
            maxHealth: BossConstants.maxHealth
        )
        self.anchorPoint = CGPoint(x: 0.5, y: 0)
        self.zPosition = 40
        self.colorBlendFactor = 0
        addChild(visual)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Atlas

    func attachAtlas(_ atlas: SpriteAtlas) {
        self.atlas = atlas
        visual.colorBlendFactor = 0
        playAnimation("idle", repeating: true)
    }

    func playAnimation(_ tag: String, repeating: Bool = true) {
        guard let atlas, currentAnimationTag != tag else { return }
        guard let anim = atlas.animation(tag) else {
            if tag != "idle" { playAnimation("idle", repeating: true) }
            return
        }
        currentAnimationTag = tag
        visual.removeAction(forKey: "anim")
        visual.texture = anim.textures[0]
        if anim.textures.count == 1 { return }
        let action = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
        let runner = repeating ? SKAction.repeatForever(action) : action
        visual.run(runner, withKey: "anim")
    }

    // MARK: - State

    var isAttacking: Bool {
        guard let attack = activeAttack else { return false }
        return !attack.isFinished
    }

    func stun(duration: TimeInterval) {
        isStunned = true
        stunTimer = duration
        activeAttack = nil
        velocity.dx = 0
    }

    override func takeDamage(_ amount: CGFloat, inflicterX: CGFloat? = nil) -> Bool {
        // Godot BossDamage.tscn applies no knockback — Sigma flinches via
        // invulnerability frames only, holding position so attack timing is
        // not derailed by player shots. Match by NOT mutating velocity here.
        return super.takeDamage(amount, inflicterX: inflicterX)
    }

    func tick(_ dt: TimeInterval, stageWidth: CGFloat, floorY: CGFloat) {
        if stunTimer > 0 {
            stunTimer = max(0, stunTimer - dt)
            if stunTimer == 0 { isStunned = false }
        }

        applyGravity(dt)
        integrate(dt)
        clampToStage(width: stageWidth, floorY: floorY)
        tickFloorTimer(dt)
        advance(dt)

        // Tick active attack after physics so state reads match the new position.
        if let attack = activeAttack {
            attack.tick(dt)
            if attack.isFinished {
                activeAttack = nil
                velocity.dx = 0
                // Return to idle animation between attacks. Godot `EndAbility`
                // lets the AbilityUser fall back to Idle which re-triggers
                // `turn_and_face_player` + idle animation; Swift has no Idle
                // ability, so we reset the sprite tag directly.
                playAnimation("idle", repeating: true)
            }
        }
    }

    var hitbox: CGRect {
        CGRect(x: position.x - size.width / 2, y: position.y, width: size.width, height: size.height)
    }

    /// World-space cannon mouth — where the OverdriveAttack laser beam emerges
    /// and the charge-windup ring sits. Tracks the boss's current facing.
    var muzzlePosition: CGPoint {
        CGPoint(
            x: position.x + facing.sign * Self.muzzleOffsetX,
            y: position.y + Self.muzzleOffsetY
        )
    }

    /// Reset to idle-safe state — used when an attack is interrupted (e.g. desperation trigger).
    func interruptAttack() {
        activeAttack = nil
        velocity.dx = 0
        gravityScale = 1.0
    }

    /// Begin the BossDeath cutscene visuals. Mirrors Godot BossDeath._Setup:
    /// freeze velocity, play the `death` animation once and let the sprite
    /// hold on its final frame for the explosion barrage. The scene drives
    /// timing — this method only owns the boss-side visual transition.
    func enterDeathSequence() {
        activeAttack = nil
        velocity = .zero
        gravityScale = 0
        // Godot keeps the sprite paused on the death frame during the 1 s
        // freeze + 10 s explosion window; play once so the loop doesn't
        // restart while the scene drives the burst cadence.
        playAnimation("death", repeating: false)
    }

    /// Hide the boss sprite. Used at the end of the death sequence when the
    /// background fades out. Godot calls `sprite.visible = false` and
    /// `reploid.visible = false` in `end_explosion`.
    func setVisualHidden(_ hidden: Bool) {
        visual.isHidden = hidden
    }
}
