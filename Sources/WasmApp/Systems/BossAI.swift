import Foundation
import OpenSpriteKit

// MARK: - BossAI
// Attack scheduler — picks next attack, enforces cooldowns, triggers desperation.
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/BossAI.gd

@MainActor
final class BossAI {
    enum AttackKind: Int, CaseIterable {
        case groundCombo
        case jumpCombo
        case lanceThrow
        case airCombo
    }

    // Strong reference — the context weak-holds the scene, so there is no
    // cycle. Holding it weakly caused the inline `SceneAttackContext(scene: self)`
    // init to deallocate the context before the first tick.
    private let context: AttackContext
    private var rng = BossRNG()
    private var active: Bool = false
    private var usedDesperation: Bool = false
    private(set) var cooldown: TimeInterval = 1.0
    private(set) var timer: TimeInterval = 0
    private var order: [AttackKind] = []
    private(set) var cursor: Int = 0
    var isActive: Bool { active }
    var orderCount: Int { order.count }

    init(context: AttackContext) {
        self.context = context
    }

    func activate() {
        guard !active else { return }
        active = true
        decideOrder()
        timer = 0
        cooldown = 1.0
        // Godot Idle._Setup runs turn_and_face_player on idle entry. Sigma's
        // scene sets should_turn=false so its Idle doesn't re-face, but the
        // initial Intro→Fighting transition has no explicit facing setup, and
        // our port's boss can drift during attacks. Facing on activation +
        // between attacks (below) self-corrects any drift.
        context.boss.faceToward(x: context.player.position.x)
    }

    // Test-only: disable the scheduler and cancel whatever attack is in
    // flight. Used by the E2E harness so input-plumbing tests can assert
    // on Player state without fighting off Sigma in the middle of the window.
    func deactivate() {
        active = false
        timer = 0
        cursor = 0
        context.boss.interruptAttack()
    }

    // Test-only: start a specific attack immediately, bypassing the RNG order
    // and cooldown. Used by the visual-capture spec so each boss attack can be
    // screenshotted in isolation.
    func forceAttack(_ kind: AttackKind) {
        context.boss.interruptAttack()
        let attack: Attack
        switch kind {
        case .groundCombo: attack = GroundCombo(context: context)
        case .jumpCombo:   attack = JumpCombo(context: context)
        case .lanceThrow:  attack = LanceThrow(context: context)
        case .airCombo:    attack = AirCombo(context: context)
        }
        attack.start()
        context.boss.activeAttack = attack
        timer = 0
    }

    func forceDesperation() {
        context.boss.interruptAttack()
        let overdrive = OverdriveAttack(context: context)
        overdrive.start()
        context.boss.activeAttack = overdrive
        usedDesperation = true
        timer = 0
    }

    func tick(_ dt: TimeInterval) {
        guard active else { return }
        let boss = context.boss

        if !boss.isAttacking && !boss.isStunned {
            // Idle: track the player. Matches DarkMantis/Idle default
            // (should_turn=true) — Sigma's override to false exists so the
            // sprite doesn't flip mid-idle-animation, but our port has no
            // distinct idle-turn animation so per-frame tracking is harmless
            // and prevents boss from facing away if it drifts past the player.
            boss.faceToward(x: context.player.position.x)
            timer += dt
            if timer >= cooldown {
                executeNext()
                timer = 0
                rollNextCooldown()
            }
        } else {
            timer = 0
        }

        // Desperation trigger — interrupts current action at 50% HP.
        // Godot BossAI.gd:172 compares against `floor(max_health * threshold) - 1`,
        // so desperation triggers when currentHealth crosses BELOW the 50% mark
        // (not AT it). Missing the `- 1` shifted the trigger one HP earlier.
        if !usedDesperation && boss.currentHealth <= floor(boss.maxHealth * BossConstants.desperationThreshold) - 1 {
            usedDesperation = true
            boss.interruptAttack()
            let overdrive = OverdriveAttack(context: context)
            overdrive.start()
            boss.activeAttack = overdrive
        }
    }

    // MARK: - Order selection

    private func decideOrder() {
        order.removeAll()
        // Seed: each non-desperation attack appears at least once up-front.
        var pool = AttackKind.allCases
        while !pool.isEmpty {
            let idx = rng.randi(in: 0...pool.count - 1)
            order.append(pool[idx])
            pool.remove(at: idx)
        }
        // Fill up to 32 slots, avoiding three-in-a-row repeats.
        while order.count < 32 {
            var candidate = AttackKind.allCases[rng.randi(in: 0...AttackKind.allCases.count - 1)]
            if order.count >= 2,
               order[order.count - 1] == order[order.count - 2],
               order[order.count - 1] == candidate {
                // Godot BossAI.gd:144-147 reroll_attack: returns attack+1 only when
                // attack+1 < size-1, otherwise wraps to 0. For a 4-attack set that
                // yields: 0→1, 1→2, 2→0, 3→0 (NOT 2→3 via modulo, which is the
                // previous buggy behavior).
                let n = AttackKind.allCases.count
                let nextIdx = (candidate.rawValue + 1 < n - 1) ? candidate.rawValue + 1 : 0
                candidate = AttackKind.allCases[nextIdx]
            }
            order.append(candidate)
        }
        cursor = 0
    }

    private func executeNext() {
        let kind = order[cursor % order.count]
        cursor += 1
        let attack: Attack
        switch kind {
        case .groundCombo: attack = GroundCombo(context: context)
        case .jumpCombo:   attack = JumpCombo(context: context)
        case .lanceThrow:  attack = LanceThrow(context: context)
        case .airCombo:    attack = AirCombo(context: context)
        }
        attack.start()
        context.boss.activeAttack = attack
    }

    private func rollNextCooldown() {
        let boss = context.boss
        // Shorter cooldowns as HP drops. Mirrors Godot:
        //   max_time = (current_health * time_between_attacks.y) / max_health
        let maxTime = (boss.currentHealth * BossConstants.attackCooldownMaxAtFullHP) / boss.maxHealth
        cooldown = rng.randf(in: BossConstants.attackCooldownMin...max(BossConstants.attackCooldownMin, maxTime))
    }
}
