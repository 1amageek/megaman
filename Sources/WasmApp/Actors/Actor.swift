import Foundation
import OpenSpriteKit

// MARK: - Facing

enum Facing: Int {
    case left = -1
    case right = 1

    var opposite: Facing { self == .left ? .right : .left }
    var sign: CGFloat { CGFloat(rawValue) }
}

// MARK: - Actor
// Base behavior for characters that take damage (Player, Boss).
// Mirrors Mega-Man-X8-16-bit/src/Actors/Actor.gd + Character.gd.

@MainActor
class Actor: SKSpriteNode {
    var maxHealth: CGFloat
    private(set) var currentHealth: CGFloat
    private(set) var facing: Facing = .right

    // Physics state (manual — we don't use SKPhysicsBody for platformer movement)
    var velocity: CGVector = .zero
    var gravityScale: CGFloat = 1
    var onFloor: Bool = true
    // Godot Actor.gd `time_since_on_floor`. Reset to 0 each tick the actor is
    // grounded; otherwise accumulates dt. Jump.gd uses
    // `has_just_been_on_floor(leeway_time)` (leeway = 0.1 s) so the player can
    // still trigger a jump within ~100 ms of stepping off a ledge. The Sigma
    // arena floor is flat so this rarely fires, but the coyote-leeway is part
    // of the Jump start condition we mirror.
    private(set) var timeSinceOnFloor: TimeInterval = 0

    // Damage handling
    private var invulnerabilityTimer: TimeInterval = 0
    private var flashTimer: TimeInterval = 0
    // Godot Actor.gd separates the invulnerability TIMER (damage immunity
    // window) from the invulnerability SHADER (the visible blink). The
    // shader is removed by `PlayerDeath._Setup` so a dying actor does not
    // appear to blink during the 0.5 s death-pause before the explosion.
    // Mirror that here with a flag the death/respawn paths toggle.
    private var invulnerabilityShaderActive: Bool = true
    var damageInvulnerabilityDuration: TimeInterval { PhysicsConstants.invulnerabilityDuration }
    var isInvulnerable: Bool { invulnerabilityTimer > 0 }
    var isAlive: Bool { currentHealth > 0 }

    init(color: SKColor, size: CGSize, maxHealth: CGFloat) {
        self.maxHealth = maxHealth
        self.currentHealth = maxHealth
        super.init(texture: nil, color: color, size: size)
        // Textureless SKSpriteNode renders via layer.backgroundColor,
        // which only lights up when colorBlendFactor > 0.
        self.colorBlendFactor = 1.0
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Damage

    @discardableResult
    func takeDamage(_ amount: CGFloat, inflicterX: CGFloat? = nil) -> Bool {
        guard !isInvulnerable, isAlive else { return false }
        currentHealth = max(0, currentHealth - amount)
        invulnerabilityTimer = damageInvulnerabilityDuration
        flashTimer = PhysicsConstants.damageFlashDuration
        return true
    }

    func heal(_ amount: CGFloat) {
        currentHealth = min(maxHealth, currentHealth + amount)
    }

    /// Debug-mode max-HP override. Clamps `currentHealth` so the new ceiling
    /// is respected. The HUD's HealthBar caches its own `maxValue`, so the
    /// scene must call `HealthBar.setMaxValue(_:current:)` after this to
    /// keep the bar's ratio in sync.
    func setMaxHealth(_ value: CGFloat) {
        let newMax = max(1, value)
        maxHealth = newMax
        currentHealth = min(currentHealth, newMax)
    }

    /// Mirrors Godot `character.remove_invulnerability_shader()`. Stops the
    /// alpha blink in `advance(_:)` while the i-frame timer keeps running.
    /// Called at death so the dying sprite is fully visible (or fully
    /// hidden by the death sequence) rather than flashing.
    func removeInvulnerabilityShader() {
        invulnerabilityShaderActive = false
    }

    /// Mirrors Godot `character.apply_invulnerability_shader()`. Restores
    /// the alpha blink — used on respawn so a fresh life behaves normally
    /// after a death that disabled the shader.
    func applyInvulnerabilityShader() {
        invulnerabilityShaderActive = true
    }

    /// Debug-only — set HP directly, bypassing damage rules and i-frames. Used
    /// by the test harness to skip the desperation threshold or test edge HP
    /// values without simulating damage.
    func debugSetHealth(_ value: CGFloat) {
        currentHealth = max(0, min(maxHealth, value))
    }

    // MARK: - Facing

    func face(_ facing: Facing) {
        guard self.facing != facing else { return }
        self.facing = facing
        xScale = facing.sign * abs(xScale)
    }

    func faceToward(x targetX: CGFloat) {
        face(targetX < position.x ? .left : .right)
    }

    // MARK: - Physics tick

    func applyGravity(_ dt: TimeInterval) {
        guard !onFloor else { return }
        velocity.dy -= PhysicsConstants.gravity * gravityScale * CGFloat(dt)
        velocity.dy = max(velocity.dy, -PhysicsConstants.maxFallVelocity)
    }

    func integrate(_ dt: TimeInterval) {
        position.x += velocity.dx * CGFloat(dt)
        position.y += velocity.dy * CGFloat(dt)
    }

    func clampToStage(width: CGFloat, floorY: CGFloat) {
        let halfW = size.width / 2
        position.x = max(halfW, min(width - halfW, position.x))
        if position.y <= floorY {
            position.y = floorY
            velocity.dy = 0
            onFloor = true
        } else {
            onFloor = false
        }
    }

    /// Mirrors Godot Character.gd `check_for_land(delta)`. Reset
    /// `timeSinceOnFloor` while grounded; otherwise accumulate. Call this
    /// once per physics tick AFTER `clampToStage` has updated `onFloor`.
    func tickFloorTimer(_ dt: TimeInterval) {
        if onFloor {
            timeSinceOnFloor = 0
        } else {
            timeSinceOnFloor += dt
        }
    }

    /// Godot Actor.gd `has_just_been_on_floor(leeway)` — true while grounded
    /// or within `leeway` seconds of leaving the floor (jump coyote-window).
    func hasJustBeenOnFloor(leeway: TimeInterval) -> Bool {
        onFloor || timeSinceOnFloor < leeway
    }

    // MARK: - Frame update

    func advance(_ dt: TimeInterval) {
        if invulnerabilityTimer > 0 {
            invulnerabilityTimer = max(0, invulnerabilityTimer - dt)
        }
        if flashTimer > 0 {
            flashTimer = max(0, flashTimer - dt)
            alpha = 0.6
        } else if isInvulnerable, invulnerabilityShaderActive {
            let blink = Int(invulnerabilityTimer * 20) % 2 == 0
            alpha = blink ? 0.4 : 1.0
        } else {
            alpha = 1.0
        }
    }
}
