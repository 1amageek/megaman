import Foundation
import OpenSpriteKit

// MARK: - SigmaIntro
// 9-stage scripted intro for Satan Sigma. Ports
// Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/Intro.gd 1:1 — stage
// numbering matches Godot's `attack_stage` exactly. Per-stage animation
// durations come from satan_sigma.json frame sums (see comments).

@MainActor
final class SigmaIntro {
    // Godot stage→stage wait timers (`timer > N` guards in Intro.gd).
    private static let stage2Wait: TimeInterval = 0.1
    private static let stage3Wait: TimeInterval = 0.25
    private static let stage6Wait: TimeInterval = 0.65
    private static let stage7Wait: TimeInterval = 1.55

    // Atlas-authored animation durations (sum of per-frame `duration` in
    // satan_sigma.json). Godot's `has_finished_last_animation()` returns
    // true once the AnimatedSprite2D reaches its final frame — we
    // approximate that with a wall-clock gate against the same total.
    private static let introAnimDuration: TimeInterval = 1.126     // frames 122-136
    private static let intro2AnimDuration: TimeInterval = 0.462    // frames 137-142
    private static let introEndAnimDuration: TimeInterval = 0.620  // frames 143-151

    private unowned let scene: BossBattleScene
    private unowned let boss: Boss

    private(set) var stage: Int = 0
    private(set) var isFinished: Bool = false
    private var timer: TimeInterval = 0

    init(scene: BossBattleScene, boss: Boss) {
        self.scene = scene
        self.boss = boss
    }

    func reset() {
        stage = 0
        timer = 0
        isFinished = false
    }

    func begin() {
        // Godot Intro.gd stage 0: `play_animation("seated_loop")`. Called
        // on scene build and on every reset so the boss shows the throne
        // pose immediately rather than the default idle frame.
        boss.playAnimation("seated_loop", repeating: true)
    }

    func tick(_ dt: TimeInterval) {
        guard !isFinished else { return }
        timer += dt
        switch stage {
        case 0:
            // stage 0: `start_dialog_or_go_to_attack_stage(2)`. Our port has
            // no dialog, so `seen_dialog()` is effectively true and the
            // helper calls `go_to_attack_stage(2)` — skipping stage 1.
            boss.playAnimation("seated_loop", repeating: true)
            jump(to: 2)
        case 1:
            // Unused in our port (dialog path). Left for structural parity.
            jump(to: 2)
        case 2:
            if timer >= Self.stage2Wait { advance() }
        case 3:
            if timer >= Self.stage3Wait {
                boss.playAnimation("intro", repeating: false)
                scene.onBossMusicStart()
                advance()
            }
        case 4:
            if timer >= Self.introAnimDuration {
                boss.playAnimation("intro2", repeating: false)
                scene.spawnIntroFlash()
                scene.spawnThroneExplosion()
                // Godot Intro.gd stage 4: `Event.emit_signal("sigma_walls")`
                // wakes the two SigmaWall pillars so they rise from below the
                // floor during the same beat that the throne shatters.
                scene.activateSigmaWalls()
                scene.startScreenShake(duration: 0.3, amplitude: 3)
                advance()
            }
        case 5:
            if timer >= Self.intro2AnimDuration {
                boss.playAnimation("intro_loop", repeating: true)
                advance()
            }
        case 6:
            if timer >= Self.stage6Wait {
                scene.onBossHealthAppear()
                advance()
            }
        case 7:
            if timer >= Self.stage7Wait {
                boss.playAnimation("intro_end", repeating: false)
                advance()
            }
        case 8:
            if timer >= Self.introEndAnimDuration {
                boss.playAnimation("idle", repeating: true)
                scene.onIntroConcluded()
                isFinished = true
            }
        default:
            isFinished = true
        }
    }

    private func advance() {
        stage += 1
        timer = 0
    }

    private func jump(to next: Int) {
        stage = next
        timer = 0
    }
}
