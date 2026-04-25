import Foundation
import OpenSpriteKit

// MARK: - OverdriveAttack
// Boss desperation move — charges, then fires a long horizontal laser beam.
// Triggered once when HP drops below 50%.
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/OverdriveAttack.gd

@MainActor
final class OverdriveAttack: Attack {
    private enum Stage {
        case prepare
        case chargeLoop
        case startFiring
        case firing
        case cooldown
        case end
        case done
    }

    private weak var context: AttackContext?
    private var stage: Stage = .prepare
    private var timer: TimeInterval = 0
    private(set) var isFinished: Bool = false
    let currentHitbox: CGRect? = nil
    let hitboxDamage: CGFloat = 0
    private var laser: Projectile?
    /// Godot OverdriveAttack.gd:44 — `tween_speed(-abs(distance_to_back_wall), 0, 2.4)`
    /// sets initial recoil magnitude from the boss→rear-wall distance and decays
    /// linearly to 0 over the 2.4s firing window. Stored at fire start so `.firing`
    /// can interpolate it frame-by-frame.
    private var recoilStartSpeed: CGFloat = 0
    /// Weak handle to the charge-windup effect so it can be removed when
    /// firing begins (otherwise the 1.6s-wide auto-remove would overlap the
    /// beam for a beat).
    private weak var chargeEffect: SKNode?

    init(context: AttackContext) {
        self.context = context
    }

    // Debug accessors — let the test harness inspect the FSM without
    // smuggling state through side channels.
    var debugStageName: String {
        switch stage {
        case .prepare:     return "prepare"
        case .chargeLoop:  return "chargeLoop"
        case .startFiring: return "startFiring"
        case .firing:      return "firing"
        case .cooldown:    return "cooldown"
        case .end:         return "end"
        case .done:        return "done"
        }
    }
    var debugTimer: TimeInterval { timer }
    var debugContextAlive: Bool { context != nil }
    var debugLaserPosition: CGPoint? { laser?.position }
    var debugLaserAlive: Bool { laser?.isAlive ?? false }

    func start() {
        guard let context else { return }
        stage = .prepare
        timer = 0
        isFinished = false
        context.boss.faceToward(x: context.player.position.x)
        context.boss.velocity = .zero
        context.boss.playAnimation("cannon_prepare", repeating: false)

        // Charge windup visual — converging sparks + pulsing ring at the
        // cannon mouth. Godot OverdriveAttack.gd spawns a charge_circle +
        // ParticleProcessMaterial during cannon_prepare/cannon_prepare_loop
        // (≈1.6s combined). Without a GPU particle system we approximate with
        // SKSpriteNode + additive-blended compound actions (same pattern as
        // PlayerEffects.makeDeathSparkle). Keeping the effect in the scene so
        // the boss can move / be interrupted without leaking the node.
        let effect = BossEffects.overdriveCharge(at: context.boss.muzzlePosition, duration: 1.7)
        context.spawnEffect(effect)
        chargeEffect = effect
    }

    func tick(_ dt: TimeInterval) {
        guard let context else { return }
        timer += dt

        switch stage {
        case .prepare:
            // cannon_prepare — 0.4s windup
            if timer >= 0.4 {
                context.boss.playAnimation("cannon_prepare_loop")
                transition(to: .chargeLoop)
            }
        case .chargeLoop:
            // cannon_prepare_loop — hold for 1.2s
            if timer >= 1.2 {
                context.boss.playAnimation("cannon_start", repeating: false)
                transition(to: .startFiring)
            }
        case .startFiring:
            // cannon_start — 0.3s brief before laser appears
            if timer >= 0.3 {
                // Remove charge windup immediately when the beam commits — the
                // auto-remove in overdriveCharge() is a safety net for leaks,
                // not the normal path, so we don't wait for it.
                chargeEffect?.removeFromParent()
                chargeEffect = nil

                let muzzle = context.boss.muzzlePosition
                let flash = BossEffects.cannonFireFlash(
                    at: muzzle,
                    facing: context.boss.facing
                )
                context.spawnEffect(flash)
                let beam = ProjectileFactory.sigmaLaser(from: muzzle, facing: context.boss.facing)
                laser = beam
                context.spawnProjectile(beam)
                // Godot OverdriveAttack.gd:40 fires `sigma_desperation` with the
                // facing direction at this exact frame — SigmaWall listens and
                // the wall on Sigma's facing side explodes as the laser commits.
                context.emitDesperation(direction: Int(context.boss.facing.sign))
                // Godot uses a rear-facing raycast for wall distance; without one
                // here, fall back to the distance from boss to the stage edge on
                // the side opposite to facing (Godot formula halves the result).
                let sign = context.boss.facing.sign
                let rearDistance: CGFloat = sign > 0
                    ? context.boss.position.x                    // boss faces right → back wall at x=0
                    : context.stageWidth - context.boss.position.x  // boss faces left → back wall at x=width
                recoilStartSpeed = abs(rearDistance) / 2
                context.boss.velocity.dx = -sign * recoilStartSpeed
                context.boss.playAnimation("cannon_loop")
                transition(to: .firing)
            }
        case .firing:
            // Hold laser for 2.4s while sliding back with linear-decay recoil.
            if let laser {
                // Keep laser glued to the cannon mouth. Beam is 398 wide —
                // shifting half-width (199) along facing puts the cannon end
                // exactly at `muzzle`.
                let muzzle = context.boss.muzzlePosition
                laser.position.x = muzzle.x + context.boss.facing.sign * 199
                laser.position.y = muzzle.y
            }
            // Godot `tween_speed(start, 0, 2.4)` — linear interpolation from the
            // initial recoil to 0 over the firing window.
            let progress = min(1.0, timer / 2.4)
            let current = recoilStartSpeed * (1.0 - CGFloat(progress))
            context.boss.velocity.dx = -context.boss.facing.sign * current
            if timer >= 2.4 {
                laser?.isAlive = false
                laser = nil
                context.boss.velocity.dx = 0
                context.boss.playAnimation("cannon_end_loop")
                transition(to: .cooldown)
            }
        case .cooldown:
            // cannon_end_loop — 1s recovery, boss is stunned
            if timer >= 1.0 {
                context.boss.playAnimation("cannon_end", repeating: false)
                transition(to: .end)
            }
        case .end:
            // cannon_end — 0.4s return to neutral
            if timer >= 0.4 {
                transition(to: .done)
            }
        case .done:
            isFinished = true
        }
    }

    private func transition(to next: Stage) {
        stage = next
        timer = 0
    }
}
