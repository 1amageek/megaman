import Foundation
import OpenSpriteKit

// MARK: - GroundCombo
// 3-slash melee combo, with a projectile wave on the third slash.
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/GroundCombo.gd

@MainActor
final class GroundCombo: Attack {
    private enum Stage {
        case prepare1
        case slash1
        case hold1
        case prepare2
        case slash2
        case hold2
        case branch
        case prepare3
        case slash3
        case hold3
        case done
    }

    private weak var context: AttackContext?
    private var stage: Stage = .prepare1
    private var timer: TimeInterval = 0
    private(set) var isFinished: Bool = false

    private(set) var currentHitbox: CGRect?
    private(set) var hitboxDamage: CGFloat = WeaponConstants.sigmaMeleeDamage
    private var slash3ProjectileSpawned = false

    init(context: AttackContext) {
        self.context = context
    }

    func start() {
        guard let context else { return }
        stage = .prepare1
        timer = 0
        isFinished = false
        slash3ProjectileSpawned = false
        context.boss.faceToward(x: context.player.position.x)
        context.boss.velocity.dx = 0
        context.boss.playAnimation("slash_1_prepare", repeating: false)
    }

    func tick(_ dt: TimeInterval) {
        guard let context else { return }
        timer += dt
        currentHitbox = nil

        switch stage {
        case .prepare1:
            // Godot stage 0 (GroundCombo.gd:16-18) is animation-only: play
            // slash_1_prepare_loop and wait. No forward motion until slash_1
            // itself starts.
            context.boss.velocity.dx = 0
            if timer >= 0.35 {
                context.boss.playAnimation("slash_1", repeating: false)
                transition(to: .slash1)
            }
        case .slash1:
            // Godot stage 2 (GroundCombo.gd:24-30) activates slash_1 AND
            // tween_speed(220, 0, 0.35) — the slash slides forward while
            // the hitbox is up. Sigma.tscn slash1.active_duration = 0.1.
            // Swift previously ran this tween during prepare1 (boss stationary
            // during slash), which whiffed whenever the player hadn't been
            // kissed before the wind-up ended.
            context.boss.velocity.dx = context.boss.facing.sign * max(0, 220 - CGFloat(timer / 0.35) * 220)
            if timer < 0.1 {
                currentHitbox = meleeHitbox(context: context, width: 36, height: 40)
            }
            if timer >= 0.35 {
                context.boss.playAnimation("slash_1_loop")
                transition(to: .hold1)
            }
        case .hold1:
            context.boss.velocity.dx = 0
            if timer >= 0.1 {
                context.boss.faceToward(x: context.player.position.x)
                context.boss.playAnimation("slash_2_prepare", repeating: false)
                transition(to: .prepare2)
            }
        case .prepare2:
            // Godot stage 4 (GroundCombo.gd:36-40) runs its own tween 220→0,0.35
            // during slash_2_prepare — the prepare itself slides forward.
            context.boss.velocity.dx = context.boss.facing.sign * max(0, 220 - CGFloat(timer / 0.35) * 220)
            if timer >= 0.3 {
                context.boss.playAnimation("slash_2", repeating: false)
                transition(to: .slash2)
            }
        case .slash2:
            // Godot stage 6 tween_speed(100, 0, 0.5) — longer, slower glide
            // during slash_2. Sigma.tscn slash2.active_duration = 0.1.
            context.boss.velocity.dx = context.boss.facing.sign * max(0, 100 - CGFloat(timer / 0.5) * 100)
            if timer < 0.1 {
                currentHitbox = meleeHitbox(context: context, width: 44, height: 44)
            }
            if timer >= 0.5 {
                context.boss.playAnimation("slash_2_loop")
                transition(to: .hold2)
            }
        case .hold2:
            if timer >= 0.25 { transition(to: .branch) }
        case .branch:
            // Godot GroundCombo.gd:60 triggers slash_3 only when the player is
            // ABOVE the boss (i.e. jumped) AND in facing direction. Godot Y is
            // screen-space (down positive) so `player.y < boss.y` is above;
            // this port uses Y-up, so the inequality flips to `player.y > boss.y`.
            let isAbove = context.player.position.y > context.boss.position.y
            let inFront = (context.player.position.x - context.boss.position.x) * context.boss.facing.sign > 0
            if isAbove && inFront {
                context.boss.playAnimation("slash_3_prepare", repeating: false)
                transition(to: .prepare3)
            } else {
                // Godot GroundCombo.gd:66 plays slash_2_end on the non-branching
                // exit before returning to idle.
                context.boss.playAnimation("slash_2_end", repeating: false)
                transition(to: .done)
            }
        case .prepare3:
            // Godot stage 8 sets tween_speed(20) — a small forward creep
            // while winding up slash_3. Not damped to 0 here (Godot pins
            // the target speed until next stage).
            context.boss.velocity.dx = context.boss.facing.sign * 20
            if timer >= 0.25 {
                context.boss.playAnimation("slash_3", repeating: false)
                transition(to: .slash3)
            }
        case .slash3:
            // Godot stage 9 sets tween_speed(70) during slash_3.
            context.boss.velocity.dx = context.boss.facing.sign * 70
            // Third slash spawns a projectile wave at start. Godot GroundCombo.gd:105
            // spawns it with `proj.speed * 1.5 * target_dir` where target_dir is
            // the normalized vector to the player. Swift previously emitted a
            // horizontal-only wave at base speed, which a jumping player could
            // simply duck underneath. Active hitbox window is 0.1s
            // (Sigma.tscn GroundCombo/slash3 active_duration=0.1).
            if !slash3ProjectileSpawned {
                slash3ProjectileSpawned = true
                let origin = CGPoint(x: context.boss.position.x + context.boss.facing.sign * 24,
                                     y: context.boss.position.y + 28)
                let target = CGPoint(x: context.player.position.x,
                                     y: context.player.position.y + Player.bodySize.height / 2)
                context.spawnProjectile(ProjectileFactory.sigmaBallAimed(from: origin, target: target, speedMultiplier: 1.5))
            }
            if timer < 0.1 {
                currentHitbox = meleeHitbox(context: context, width: 50, height: 48)
            }
            if timer >= 0.2 {
                context.boss.playAnimation("slash_3_loop")
                transition(to: .hold3)
            }
        case .hold3:
            if timer >= 0.3 {
                context.boss.playAnimation("slash_3_end", repeating: false)
                transition(to: .done)
            }
        case .done:
            isFinished = true
            context.boss.velocity.dx = 0
        }
    }

    private func meleeHitbox(context: AttackContext, width: CGFloat, height: CGFloat) -> CGRect {
        let dir = context.boss.facing.sign
        let x = context.boss.position.x + dir * context.boss.size.width / 2
        let originX = dir > 0 ? x : x - width
        return CGRect(x: originX, y: context.boss.position.y + 8, width: width, height: height)
    }

    private func transition(to next: Stage) {
        stage = next
        timer = 0
        if next == .prepare3 {
            slash3ProjectileSpawned = false
        }
    }
}
