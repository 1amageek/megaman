import Foundation
import OpenSpriteKit

// MARK: - JumpCombo
// Boss dashes toward player, leaps high, and slashes twice mid-air.
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/JumpCombo.gd

@MainActor
final class JumpCombo: Attack {
    private enum Stage {
        case prepare
        case approach
        case groundSlash
        case rising
        case falling
        case landed
        case done
    }

    private weak var context: AttackContext?
    private var stage: Stage = .prepare
    private var timer: TimeInterval = 0
    private(set) var isFinished: Bool = false
    private(set) var currentHitbox: CGRect?
    let hitboxDamage: CGFloat = WeaponConstants.sigmaMeleeDamage
    // Cached jump-launch h-speed magnitude — Godot tween_speed(initial, 150, 0.7)
    // captures the value at jump moment and decays toward 150 over 0.7 s.
    private var jumpHSpeedInitial: CGFloat = 0
    private var jumpHSpeedSign: CGFloat = 1
    private var jumpAirTimer: TimeInterval = 0

    init(context: AttackContext) {
        self.context = context
    }

    func start() {
        guard let context else { return }
        stage = .prepare
        timer = 0
        isFinished = false
        context.boss.faceToward(x: context.player.position.x)
        context.boss.playAnimation("slashjump_prepare", repeating: false)
    }

    func tick(_ dt: TimeInterval) {
        guard let context else { return }
        timer += dt
        currentHitbox = nil

        switch stage {
        case .prepare:
            // Godot stage 0/1: Sigma is stationary during slashjump_prepare /
            // slashjump_prepare_loop. NO horizontal motion until the jump
            // launches at stage 3.
            context.boss.velocity.dx = 0
            if timer >= 0.2 {
                context.boss.playAnimation("slashjump_start", repeating: false)
                transition(to: .approach)
            }
        case .approach:
            // Godot stage 1 → 2: anim_finish of slashjump_start triggers
            // slashjump_slash + slash_1.activate. start_forced_movement(0)
            // is called explicitly — Sigma stays put on the ground.
            context.boss.velocity.dx = 0
            if timer >= 0.2 {
                context.boss.playAnimation("slashjump_slash", repeating: false)
                transition(to: .groundSlash)
            }
        case .groundSlash:
            // Stage 2: slash_1 active_duration = 0.1 s on the ground (Sigma
            // does NOT slide forward — that is the JumpCombo difference from
            // GroundCombo). Then stage 3 launches the actual jump arc.
            if timer < 0.1 {
                currentHitbox = slashHitbox(context: context, width: 44, height: 40)
            }
            if timer >= 0.25 {
                // Godot JumpCombo.gd:84-87 uses TOTAL (Euclidean) distance to
                // player, not horizontal-only. Clamp(distance*3, 300, 450).
                let dx = context.player.position.x - context.boss.position.x
                let dy = context.player.position.y - context.boss.position.y
                let dist = sqrt(dx * dx + dy * dy)
                let jumpVy = min(450, max(300, dist * 3))
                // Godot stage 3: tween_speed(get_initial_jump_speed(), 150, .7)
                // captures the h-speed at launch and decays it toward 150 over
                // 0.7 s. get_initial_jump_speed = abs(dx) * (dx > 150 ? 2 : 1).
                let absDx = abs(dx)
                jumpHSpeedInitial = absDx > 150 ? absDx * 2 : absDx
                jumpHSpeedSign = dx >= 0 ? 1 : -1
                jumpAirTimer = 0
                context.boss.velocity.dx = jumpHSpeedSign * jumpHSpeedInitial
                context.boss.velocity.dy = jumpVy
                context.boss.onFloor = false
                context.boss.playAnimation("slashjump_jump", repeating: false)
                transition(to: .rising)
            }
        case .rising:
            // Stage 3 → 4 in Godot: tween h-speed from initial → 150 over
            // 0.7 s while gravity carries Sigma through the apex. Mirror the
            // linear ease here.
            jumpAirTimer += dt
            let progress = min(1.0, jumpAirTimer / 0.7)
            let hSpeed = jumpHSpeedInitial + (150 - jumpHSpeedInitial) * CGFloat(progress)
            context.boss.velocity.dx = jumpHSpeedSign * hSpeed
            // Godot JumpCombo.gd:43 transitions once FALL speed > 150 (i.e. well
            // past apex, not at apex). Then it FORCE-SETS fall velocity to 350
            // for the drop-kick feel. Swift-up-positive convention: trigger at
            // dy < -150, then set dy = -350.
            if context.boss.velocity.dy < -150 {
                currentHitbox = slashHitbox(context: context, width: 40, height: 40)
                context.boss.velocity.dy = -350
                context.boss.playAnimation("slashjump_fall", repeating: false)
                transition(to: .falling)
            }
        case .falling:
            // Godot Sigma.tscn JumpCombo/slash2 active_duration=2.0 AND the
            // hitbox is explicitly deactivated in JumpCombo.gd:60 when Sigma
            // lands. The effective window is therefore "entire fall + until
            // ground contact", capped at 2s. Continue the h-speed tween into
            // the fall — the Godot tween runs through stages 4-5 until land.
            jumpAirTimer += dt
            let progress = min(1.0, jumpAirTimer / 0.7)
            let hSpeed = jumpHSpeedInitial + (150 - jumpHSpeedInitial) * CGFloat(progress)
            context.boss.velocity.dx = jumpHSpeedSign * hSpeed
            if timer < 2.0 {
                currentHitbox = slashHitbox(context: context, width: 40, height: 40)
            }
            if context.boss.onFloor {
                context.boss.velocity.dx = 0
                context.boss.playAnimation("slashjump_land", repeating: false)
                transition(to: .landed)
            }
        case .landed:
            if timer >= 0.25 {
                context.boss.playAnimation("slashjump_end", repeating: false)
                transition(to: .done)
            }
        case .done:
            isFinished = true
        }
    }

    private func slashHitbox(context: AttackContext, width: CGFloat, height: CGFloat) -> CGRect {
        let dir = context.boss.facing.sign
        let x = context.boss.position.x + dir * context.boss.size.width / 2
        let originX = dir > 0 ? x : x - width
        return CGRect(x: originX, y: context.boss.position.y + 6, width: width, height: height)
    }

    private func transition(to next: Stage) {
        stage = next
        timer = 0
    }
}
