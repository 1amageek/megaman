import Foundation
import OpenSpriteKit

// MARK: - AirCombo
// Boss leaps, fires two angled projectiles mid-air, then slams down (dive).
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/AirCombo.gd

@MainActor
final class AirCombo: Attack {
    private enum Stage {
        case prepare
        case rising1
        case firstSlash
        case firstProjectile
        case hold1
        case secondSlash
        case secondProjectile
        case divePrepare
        case dive
        case diving
        case landed
        case done
    }

    private weak var context: AttackContext?
    private var stage: Stage = .prepare
    private var timer: TimeInterval = 0
    private(set) var isFinished: Bool = false
    private(set) var currentHitbox: CGRect?
    let hitboxDamage: CGFloat = WeaponConstants.sigmaMeleeDamage
    private var diveActive: Bool = false
    private var didSpawnStageProjectile = false

    init(context: AttackContext) {
        self.context = context
    }

    func start() {
        guard let context else { return }
        stage = .prepare
        timer = 0
        isFinished = false
        diveActive = false
        didSpawnStageProjectile = false
        context.boss.faceToward(x: context.player.position.x)
        context.boss.velocity.dx = 0
        context.boss.playAnimation("jump_prepare", repeating: false)
    }

    func tick(_ dt: TimeInterval) {
        guard let context else { return }
        timer += dt
        currentHitbox = nil

        switch stage {
        case .prepare:
            context.boss.gravityScale = 0.89  // 700/900, forced movement -40 phase
            if timer >= 0.25 {
                context.boss.velocity.dy = 400
                context.boss.onFloor = false
                context.boss.velocity.dx = -context.boss.facing.sign * 40  // Drift back
                context.boss.playAnimation("jump", repeating: false)
                transition(to: .rising1)
            }
        case .rising1:
            // Godot AirCombo.gd:24 sets gravity_scaling = 700 at launch (stage 0).
            // Godot stage 1 (timer > 0.5) sets it back to 800. Mirror that.
            context.boss.gravityScale = 0.78  // 700/900
            if timer >= 0.5 {
                context.boss.gravityScale = 0.89  // 800/900 — restore
                context.boss.faceToward(x: context.player.position.x)
                context.boss.playAnimation("jumpslash_prepare", repeating: false)
                transition(to: .firstSlash)
            }
        case .firstSlash:
            // Godot Sigma.tscn AirCombo has ONLY a `dive` hitbox (active_duration=0.5);
            // there are no slash_1 / slash_2 nodes. This stage is animation-only —
            // the danger is the aimed projectile spawned in firstProjectile.
            if timer >= 0.2 {
                context.boss.playAnimation("jumpslash", repeating: false)
                transition(to: .firstProjectile)
            }
        case .firstProjectile:
            if !didSpawnStageProjectile {
                didSpawnStageProjectile = true
                let origin = CGPoint(x: context.boss.position.x + context.boss.facing.sign * 18,
                                     y: context.boss.position.y + 34)
                let target = CGPoint(x: context.player.position.x,
                                     y: context.player.position.y + Player.bodySize.height / 2)
                context.spawnProjectile(ProjectileFactory.sigmaBallAimed(from: origin, target: target, speedMultiplier: 1.25))
                context.boss.velocity.dy = 200
                context.boss.velocity.dx = -context.boss.facing.sign * 20
            }
            if timer >= 0.25 {
                context.boss.faceToward(x: context.player.position.x)
                context.boss.playAnimation("jumpslash_prepare", repeating: false)
                transition(to: .secondSlash)
            }
        case .hold1:
            if timer >= 0.25 { transition(to: .secondSlash) }
        case .secondSlash:
            // No hitbox — see `firstSlash` comment. Projectile is the threat.
            if timer >= 0.2 {
                context.boss.playAnimation("jumpslash", repeating: false)
                transition(to: .secondProjectile)
            }
        case .secondProjectile:
            if !didSpawnStageProjectile {
                didSpawnStageProjectile = true
                let origin = CGPoint(x: context.boss.position.x + context.boss.facing.sign * 20,
                                     y: context.boss.position.y + 34)
                let target = CGPoint(x: context.player.position.x,
                                     y: context.player.position.y + Player.bodySize.height / 2)
                context.spawnProjectile(ProjectileFactory.sigmaBallAimed(from: origin, target: target, speedMultiplier: 1.25))
                context.boss.velocity.dy = 250
                // Godot AirCombo.gd:58 `start_forced_movement(abs(distance)/2)` —
                // uncapped. Swift previously clamped at 80 which left Sigma short
                // of the player when they were > 160 px apart.
                let dx = context.player.position.x - context.boss.position.x
                context.boss.velocity.dx = (dx >= 0 ? 1 : -1) * abs(dx) / 2
            }
            if timer >= 0.5 {
                context.boss.playAnimation("dive_prepare", repeating: false)
                transition(to: .divePrepare)
            }
        case .divePrepare:
            context.boss.gravityScale = 0.44  // 400/900
            if timer < 0.05 {
                // Godot AirCombo.gd:65-67 initial push — `set_vertical_speed(-100)`
                // upward bump and `tween_speed(abs(dx)*3.5, 0, 0.5)` horizontal
                // rush toward the player, decaying to 0 over the 0.5s window.
                // Swift previously entered with only the much smaller
                // secondProjectile drift (min(80, dx/2)) and relied on the
                // 0.85 per-frame decay, so Sigma never charged the player.
                context.boss.velocity.dy = 100
                let dx = context.player.position.x - context.boss.position.x
                context.boss.velocity.dx = (dx >= 0 ? 1 : -1) * abs(dx) * 3.5
            } else {
                context.boss.velocity.dx *= 0.85  // Decay the initial rush toward 0.
            }
            if timer >= 0.5 {
                context.boss.faceToward(x: context.player.position.x)
                context.boss.playAnimation("dive")
                transition(to: .dive)
            }
        case .dive:
            // Slam straight down
            context.boss.velocity.dy = -600
            context.boss.velocity.dx = 0
            diveActive = true
            transition(to: .diving)
        case .diving:
            if diveActive {
                currentHitbox = diveHitbox(context: context)
            }
            if context.boss.onFloor || timer > 5 {
                diveActive = false
                context.boss.gravityScale = 1.0
                context.boss.playAnimation("dive_land", repeating: false)
                transition(to: .landed)
            }
        case .landed:
            context.boss.velocity.dx = 0
            if timer >= 0.5 {
                context.boss.playAnimation("dive_end", repeating: false)
                transition(to: .done)
            }
        case .done:
            isFinished = true
            context.boss.gravityScale = 1.0
        }
    }

    private func slashHitbox(context: AttackContext, width: CGFloat, height: CGFloat) -> CGRect {
        let dir = context.boss.facing.sign
        let x = context.boss.position.x + dir * context.boss.size.width / 2
        let originX = dir > 0 ? x : x - width
        return CGRect(x: originX, y: context.boss.position.y + 10, width: width, height: height)
    }

    private func diveHitbox(context: AttackContext) -> CGRect {
        let w: CGFloat = context.boss.size.width + 12
        return CGRect(x: context.boss.position.x - w / 2,
                      y: context.boss.position.y - 4,
                      width: w,
                      height: context.boss.size.height + 6)
    }

    private func transition(to next: Stage) {
        stage = next
        timer = 0
        didSpawnStageProjectile = false
    }
}
