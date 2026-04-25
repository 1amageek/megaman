import Foundation
import OpenSpriteKit

// MARK: - Attack protocol
// Each boss attack is a state machine driven by the BossAI.
// Source: Mega-Man-X8-16-bit/src/Actors/Abilities/AttackAbility.gd

@MainActor
protocol Attack: AnyObject {
    var isFinished: Bool { get }
    func start()
    func tick(_ dt: TimeInterval)
    /// Optional damaging hitbox at the current frame — scene uses this for melee hit detection.
    var currentHitbox: CGRect? { get }
    /// Damage dealt by the currentHitbox.
    var hitboxDamage: CGFloat { get }
}

@MainActor
protocol AttackContext: AnyObject {
    var boss: Boss { get }
    var player: Player { get }
    /// Stage width — needed by OverdriveAttack to size its back-wall recoil, which
    /// Godot computes via a rear-facing raycast (no raycast system in this port).
    var stageWidth: CGFloat { get }
    /// Floor Y in Y-up coordinates. Used by LanceThrow's raycast to find the
    /// throw-line collision point with the floor (Godot Lance.gd uses
    /// lance_raycast which collides with scenery; in the port we resolve
    /// against the arena bounding box).
    var floorY: CGFloat { get }
    /// Inner arena wall X coordinates. The boss arena is bounded by SigmaWall
    /// pillars at x=16 (left) and x=stageWidth-16 (right). Lance raycast
    /// terminates at these.
    var arenaWallLeft: CGFloat { get }
    var arenaWallRight: CGFloat { get }
    func spawnProjectile(_ projectile: Projectile)
    /// Add a purely visual node (no hitbox) to the scene. Used by attacks that
    /// need to show windup/flash/impact effects authored in `BossEffects`.
    func spawnEffect(_ node: SKNode)
    /// Mirrors Godot `Event.emit_signal("sigma_desperation", direction)`.
    /// SigmaWall instances listen for this and explode if their `direction`
    /// matches. Direction is the boss's facing sign at the firing moment.
    func emitDesperation(direction: Int)
    /// Mirrors Godot `Event.emit_signal("screenshake", value)` — used by
    /// LanceThrow at jump (2.0), throw (0.5), and land (2.0) moments.
    func screenshake(amplitude: CGFloat, duration: TimeInterval)
}
