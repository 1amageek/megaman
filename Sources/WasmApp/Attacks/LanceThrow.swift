import Foundation
import OpenSpriteKit

// MARK: - LanceThrow
// Boss jumps, aims, throws a lance projectile, lands.
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/LanceThrow.gd
//         + Lance.gd / Lance.tscn (the projectile half is in BossEffects +
//         ProjectileFactory.sigmaLance)
//
// Godot stage map:
//   0 → wait `spear_jump_prepare` finished, then jump (vy = -300), screenshake,
//       tween_speed(-40,0,1), play `spear_prepare`, charge SE, laser visible
//   1 → wait timer > 0.15, lock target_dir = player_pos, targetting = false
//   2 → wait timer > 0.35, play `spear_throw`, projectile_sfx
//   3 → wait `spear_throw` finished: charge.stop, play `spear_throw_end`,
//       laser → "fire", instantiate_spear() (raycast collision point),
//       screenshake(0.5), tween_speed(-100,0,1), vy = -100; if first-throw
//       gravity 600→300 → stage 4, else gravity 300→600 → stage 5
//   4 → wait `spear_throw_end` finished: charge re-play, tween_speed(-40,0,1),
//       play `spear_prepare`, vy = -110, targetting = true → goto stage 1
//   5 → wait on_floor: play `land`, land SE, laser hidden, screenshake
//   6 → wait `land` finished: EndAbility

@MainActor
final class LanceThrow: Attack {
    private enum Stage {
        case stage0_jumpPrepare
        case stage1_lockWindow
        case stage2_throwWindow
        case stage3_spawn
        case stage4_repeatPrepare
        case stage5_landWait
        case stage6_landRecover
        case done
    }

    private weak var context: AttackContext?
    private var stage: Stage = .stage0_jumpPrepare
    private var stageTimer: TimeInterval = 0
    private(set) var isFinished: Bool = false

    // Godot LanceThrow.gd: target_dir locked at stage 1 (after 0.15s into the
    // spear_prepare animation that started at stage 0→1 transition). The lock
    // is the player position at that moment, NEVER re-sampled — that gap is
    // what gives the player ~0.35s to dodge before the lance is instantiated
    // at stage 3.
    private var targetDir: CGPoint = .zero
    private var targetting: Bool = true

    // Godot uses `repeat_attack: true` initially → flips false on first throw
    // → drives the stage 3 branch (gravity 300 + go to stage 4) vs (gravity
    // 600 + go to stage 5).
    private var repeatAttack: Bool = true

    // Godot stage 0 conditions on `has_finished_last_animation()` of
    // spear_jump_prepare; stages 3, 4, 6 likewise wait on the named animation
    // to finish. The Swift port has no AnimationPlayer.has_finished_last hook,
    // so each named animation is approximated with its measured frame budget.
    // Sources: AsepriteWizard tag durations from sigma.json — values below
    // are conservative upper bounds matching the visual length of each tag.
    private let durSpearJumpPrepare: TimeInterval = 0.25
    private let durSpearThrow: TimeInterval = 0.20
    private let durSpearThrowEnd: TimeInterval = 0.20
    private let durLand: TimeInterval = 0.20

    // Godot tween_speed h-recoil. Each fire arms a magnitude → 0 ramp over 1s.
    private var hRecoilStart: CGFloat = 0
    private var hRecoilTimer: TimeInterval = 0
    private let hRecoilDuration: TimeInterval = 1.0

    // Godot gravity_scale starts 600, drops to 300 between throws (lighter
    // hang), restores to 600 on final throw. Default Boss.gravity ≈ 900 in
    // PhysicsConstants → Godot 600/900 = 0.667; 300/900 = 0.333.
    private let gravityHeavy: CGFloat = 0.67
    private let gravityLight: CGFloat = 0.33

    // Aim laser overlay — Godot LanceThrow.tscn `laser` AnimatedSprite2D
    // (24.81 × scale, ready/fire frames). Drawn here as a thin SKShapeNode
    // line that follows the boss until target lock, then freezes on the
    // locked direction. Switched to a thicker "fire" tint when stage 3 fires.
    private weak var laser: SKShapeNode?

    let currentHitbox: CGRect? = nil
    let hitboxDamage: CGFloat = 0

    init(context: AttackContext) {
        self.context = context
    }

    func start() {
        guard let context else { return }
        stage = .stage0_jumpPrepare
        stageTimer = 0
        isFinished = false
        repeatAttack = true
        targetting = true
        context.boss.faceToward(x: context.player.position.x)
        context.boss.velocity.dx = 0
        context.boss.gravityScale = gravityHeavy   // Godot _Setup: gravity_scale = 600
        context.boss.playAnimation("spear_jump_prepare", repeating: false)
    }

    func tick(_ dt: TimeInterval) {
        guard let context else { return }
        stageTimer += dt

        // tween_speed runs in parallel to stage transitions in Godot — apply
        // every tick once armed, until the duration elapses.
        if hRecoilTimer < hRecoilDuration {
            hRecoilTimer += dt
            let progress = min(1.0, hRecoilTimer / hRecoilDuration)
            let magnitude = hRecoilStart * (1 - CGFloat(progress))
            context.boss.velocity.dx = -context.boss.facing.sign * magnitude
        }

        // Aim laser tracks player while targetting=true, else freezes on
        // locked target_dir. Godot calls target_laser() every _Update.
        updateLaser(context: context)

        switch stage {
        case .stage0_jumpPrepare:
            // Godot stage 0: wait spear_jump_prepare finished, then jump
            // (vy=-300), screenshake, tween_speed(-40,0,1), play spear_prepare.
            if stageTimer >= durSpearJumpPrepare {
                context.boss.velocity.dy = 300       // Y-up flip of Godot vy=-300
                context.boss.onFloor = false
                hRecoilStart = 40
                hRecoilTimer = 0
                context.screenshake(amplitude: 2.0, duration: 0.18)
                ensureLaserVisible(context: context)
                context.boss.playAnimation("spear_prepare", repeating: false)
                transition(to: .stage1_lockWindow)
            }

        case .stage1_lockWindow:
            // Godot stage 1: timer > 0.15 → turn_and_face_player, lock
            // target_dir = player_pos, targetting = false.
            if stageTimer >= 0.15 {
                context.boss.faceToward(x: context.player.position.x)
                targetDir = context.player.position
                targetting = false
                transition(to: .stage2_throwWindow)
            }

        case .stage2_throwWindow:
            // Godot stage 2: timer > 0.35 → play spear_throw, projectile_sfx.
            // The lance is NOT spawned here — Godot waits for spear_throw to
            // finish (stage 3 condition).
            if stageTimer >= 0.35 {
                context.boss.playAnimation("spear_throw", repeating: false)
                transition(to: .stage3_spawn)
            }

        case .stage3_spawn:
            // Godot stage 3: wait spear_throw finished → instantiate_spear(),
            // screenshake(0.5), tween_speed(-100,0,1), vy=-100, play
            // spear_throw_end. Branch on repeat_attack.
            if stageTimer >= durSpearThrow {
                spawnLance(context: context)
                context.screenshake(amplitude: 0.5, duration: 0.10)
                hRecoilStart = 100
                hRecoilTimer = 0
                context.boss.velocity.dy = 100       // Y-up flip of Godot vy=-100
                context.boss.playAnimation("spear_throw_end", repeating: false)
                if repeatAttack {
                    repeatAttack = false
                    context.boss.gravityScale = gravityLight   // Godot 300
                    transition(to: .stage4_repeatPrepare)
                } else {
                    context.boss.gravityScale = gravityHeavy   // Godot 600
                    hideLaser()
                    transition(to: .stage5_landWait)
                }
            }

        case .stage4_repeatPrepare:
            // Godot stage 4: wait spear_throw_end finished → re-charge audio,
            // tween_speed(-40,0,1), play spear_prepare, vy=-110, laser visible,
            // targetting=true → goto stage 1.
            if stageTimer >= durSpearThrowEnd {
                hRecoilStart = 40
                hRecoilTimer = 0
                context.boss.velocity.dy = 110       // Y-up flip of Godot vy=-110
                context.boss.faceToward(x: context.player.position.x)
                context.boss.playAnimation("spear_prepare", repeating: false)
                ensureLaserVisible(context: context)
                targetting = true
                transition(to: .stage1_lockWindow)
            }

        case .stage5_landWait:
            // Godot stage 5: is_on_floor → play land, land SE, laser hidden,
            // screenshake.
            if context.boss.onFloor {
                context.boss.velocity.dx = 0
                context.boss.playAnimation("land", repeating: false)
                hideLaser()
                context.screenshake(amplitude: 2.0, duration: 0.18)
                transition(to: .stage6_landRecover)
            }

        case .stage6_landRecover:
            // Godot stage 6: wait land finished → EndAbility.
            if stageTimer >= durLand {
                transition(to: .done)
            }

        case .done:
            isFinished = true
            context.boss.gravityScale = 1.0
            cleanupLaser()
        }
    }

    private func transition(to next: Stage) {
        stage = next
        stageTimer = 0
    }

    // MARK: - Lance instantiation (Godot LanceThrow.gd:106-117)

    private func spawnLance(context: AttackContext) {
        // Godot lance_projectile_pos is at Sigma local (55, 40). After mirror
        // (animatedSprite.flip_h on facing change) the X is signed. Our boss
        // pivot is the body centre — apply the same offset for visual parity.
        let bossOrigin = CGPoint(
            x: context.boss.position.x + context.boss.facing.sign * 55,
            y: context.boss.position.y + 40
        )

        // Aim direction = (target_dir locked at stage 1) - bossOrigin.
        let dx = targetDir.x - bossOrigin.x
        let dy = targetDir.y - bossOrigin.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.001 else { return }
        let dirX = dx / len
        let dirY = dy / len

        // Godot lance_raycast.is_colliding(): if raycast hits no scenery the
        // spawn is skipped. Resolve against arena bounding box (left/right
        // walls + floor; ceiling beyond camera is not part of the arena
        // body in Godot either, so an upward shot misses and spawns nothing).
        guard let impact = raycastArena(
            origin: bossOrigin,
            dirX: dirX, dirY: dirY,
            wallLeft: context.arenaWallLeft,
            wallRight: context.arenaWallRight,
            floorY: context.floorY
        ) else { return }

        // Godot `instance.look_at(character.global_position)` uses the boss's
        // CharacterBody2D position (no marker offset) — pass `boss.position`,
        // not `bossOrigin` (which has the +55*sign, +40 lance_pos marker
        // offset baked in for the raycast).
        let lance = ProjectileFactory.sigmaLance(
            impact: impact,
            bossBody: context.boss.position,
            bossOrigin: bossOrigin
        )
        context.spawnProjectile(lance)

        // Update laser visual to "fire" tint. In Godot this is laser.animation
        // = "fire" — switch the SKShapeNode stroke to a brighter green.
        if let laser {
            laser.strokeColor = SKColor(red: 0.6, green: 1.0, blue: 0.45, alpha: 0.85)
            laser.lineWidth = 2
        }
    }

    /// Find the first arena boundary the ray (origin, direction) hits.
    /// Returns nil if no boundary is in the forward half-line (no wall hit
    /// = lance is not spawned, matching Godot lance_raycast.is_colliding()).
    private func raycastArena(
        origin: CGPoint,
        dirX: CGFloat, dirY: CGFloat,
        wallLeft: CGFloat, wallRight: CGFloat,
        floorY: CGFloat
    ) -> CGPoint? {
        var best: CGFloat = .infinity
        if dirX < -0.0001 {
            let t = (wallLeft - origin.x) / dirX
            if t > 0 { best = min(best, t) }
        } else if dirX > 0.0001 {
            let t = (wallRight - origin.x) / dirX
            if t > 0 { best = min(best, t) }
        }
        if dirY < -0.0001 {
            // Y-up: floor is at lower Y. dirY < 0 means the ray heads down.
            let t = (floorY - origin.y) / dirY
            if t > 0 { best = min(best, t) }
        }
        guard best.isFinite else { return nil }
        return CGPoint(x: origin.x + dirX * best, y: origin.y + dirY * best)
    }

    // MARK: - Aim laser overlay (Godot LanceThrow.tscn `laser` node)

    private func ensureLaserVisible(context: AttackContext) {
        if laser != nil { return }
        let line = SKShapeNode()
        line.strokeColor = SKColor(red: 0.45, green: 0.95, blue: 0.55, alpha: 0.55)
        line.lineWidth = 1
        line.zPosition = 55
        line.lineCap = .butt
        context.spawnEffect(line)
        laser = line
    }

    private func updateLaser(context: AttackContext) {
        guard let laser else { return }
        let originSrc = CGPoint(
            x: context.boss.position.x + context.boss.facing.sign * 55,
            y: context.boss.position.y + 40
        )
        let aim: CGPoint
        if targetting {
            aim = context.player.position
        } else {
            aim = targetDir
        }
        let dx = aim.x - originSrc.x
        let dy = aim.y - originSrc.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.001 else { return }
        // Project to arena boundary so the laser visualises the actual ray
        // path. If no boundary is hit (extremely edge case), draw a
        // 600-px-long ray to keep the visual consistent with Godot's
        // 512-target_position raycast.
        let endpoint: CGPoint = raycastArena(
            origin: originSrc,
            dirX: dx / len, dirY: dy / len,
            wallLeft: context.arenaWallLeft,
            wallRight: context.arenaWallRight,
            floorY: context.floorY
        ) ?? CGPoint(x: originSrc.x + dx / len * 600, y: originSrc.y + dy / len * 600)
        let path = CGMutablePath()
        path.move(to: originSrc)
        path.addLine(to: endpoint)
        laser.path = path
    }

    private func hideLaser() {
        laser?.isHidden = true
    }

    private func cleanupLaser() {
        laser?.removeFromParent()
        laser = nil
    }
}
