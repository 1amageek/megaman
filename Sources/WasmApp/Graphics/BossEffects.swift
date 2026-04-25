import Foundation
import OpenSpriteKit

// MARK: - BossEffects
// Visual-only effects that accompany the boss intro. Ports
// Mega-Man-X8-16-bit/src/Actors/Bosses/SatanSigma/flash.gd and the
// throne_explosion + throne_particles nodes from Sigma.tscn without an
// emitter system. Each factory returns a self-removing SKNode.

@MainActor
enum BossEffects {
    /// Large white→violet flash over the boss when the throne explodes.
    /// Mirrors Godot Sigma flash.gd properties:
    ///   initial_alpha = 0.5, initial_scale = 5.0, tween_scale_y = true
    ///   initial_color = Color.WHITE, final_color = Color(0.75, 0.6, 0.9, 1.0)
    ///   duration = 0.2s
    static func introFlash(at point: CGPoint) -> SKNode {
        // Godot flash.gd applies a CanvasItemMaterial tint to `light.png`.
        // Use the atlas when loaded; the first frame is the soft white blob
        // that the flash relies on. Compound rectangle remains as the pre-load
        // fallback so the boss intro still reads.
        if let tex = EffectAtlases.animation(.light)?.textures.first {
            let node = SKSpriteNode(texture: tex, size: CGSize(width: 128, height: 128))
            node.position = point
            node.zPosition = 55
            node.alpha = 0.5
            node.yScale = 5.0
            node.blendMode = .add
            node.colorBlendFactor = 1.0
            node.color = .white
            let targetColor = SKColor(red: 0.75, green: 0.6, blue: 0.9, alpha: 1.0)
            let tween = SKAction.group([
                SKAction.colorize(with: targetColor, colorBlendFactor: 1.0, duration: 0.2),
                SKAction.fadeOut(withDuration: 0.2),
                SKAction.scaleY(to: 0.5, duration: 0.2),
            ])
            node.run(SKAction.sequence([tween, .removeFromParent()]))
            return node
        }

        let node = SKSpriteNode(
            color: SKColor.white,
            size: CGSize(width: 120, height: 60)
        )
        node.position = point
        node.zPosition = 55
        node.alpha = 0.5
        node.yScale = 5.0
        node.colorBlendFactor = 1.0

        let targetColor = SKColor(red: 0.75, green: 0.6, blue: 0.9, alpha: 1.0)
        let tween = SKAction.group([
            SKAction.colorize(with: targetColor, colorBlendFactor: 1.0, duration: 0.2),
            SKAction.fadeOut(withDuration: 0.2),
            SKAction.scaleY(to: 0.5, duration: 0.2),
        ])
        node.run(SKAction.sequence([tween, .removeFromParent()]))
        return node
    }

    /// Expanding ring + inward-converging particles for OverdriveAttack's
    /// charge windup. Mirrors Godot OverdriveAttack.gd charge_circle +
    /// particles spawned during `cannon_prepare_loop` (1.2s hold). The ring
    /// pulses outward while small red sparks spiral inward to the boss mouth,
    /// communicating "energy being gathered". The node self-removes after
    /// `duration` seconds; callers should keep a reference only if they need
    /// to interrupt it early.
    static func overdriveCharge(at point: CGPoint, duration: TimeInterval) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 58

        if let ringTex = EffectAtlases.animation(.circle)?.textures.first {
            // Godot OverdriveAttack.gd spawns a `charge_circle` (circle.png,
            // cream donut) that pulses in scale around the cannon mouth while
            // the 1.7 s cannon_prepare_loop holds. Mirror that here with the
            // actual texture.
            let ring = SKSpriteNode(texture: ringTex, size: CGSize(width: 64, height: 64))
            ring.blendMode = .add
            ring.color = SKColor(red: 1.0, green: 0.7, blue: 0.4, alpha: 1.0)
            ring.colorBlendFactor = 0.6
            ring.alpha = 0.9
            ring.run(SKAction.repeatForever(SKAction.sequence([
                SKAction.group([
                    SKAction.scale(to: 1.15, duration: 0.32),
                    SKAction.fadeAlpha(to: 1.0, duration: 0.32),
                ]),
                SKAction.group([
                    SKAction.scale(to: 0.75, duration: 0.32),
                    SKAction.fadeAlpha(to: 0.55, duration: 0.32),
                ]),
            ])))
            container.addChild(ring)

            // Converging sparks — Godot's particle emitter spirals red shards
            // inward toward the mouth. Reuse sparks.png if available so even
            // the sub-effect stays atlas-backed.
            if let sparksAnim = EffectAtlases.animation(.sparks), let first = sparksAnim.textures.first {
                for i in 0..<6 {
                    let angle = CGFloat(i) * (.pi * 2 / 6)
                    let radius: CGFloat = 32
                    let spark = SKSpriteNode(texture: first, size: CGSize(width: 12, height: 12))
                    spark.blendMode = .add
                    spark.position = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                    let converge = SKAction.move(to: .zero, duration: 0.45)
                    converge.timingMode = .easeIn
                    let play = SKAction.animate(with: sparksAnim.textures, timePerFrame: sparksAnim.timePerFrame)
                    spark.run(SKAction.repeatForever(SKAction.sequence([
                        SKAction.run { [weak spark] in
                            spark?.position = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                            spark?.alpha = 1.0
                        },
                        SKAction.group([converge, play, SKAction.fadeOut(withDuration: 0.45)]),
                    ])))
                    container.addChild(spark)
                }
            }

            container.run(SKAction.sequence([
                .wait(forDuration: duration),
                .removeFromParent(),
            ]))
            return container
        }

        // Fallback: compound additive rays + pulsing core during pre-load.
        let rayColor = SKColor(red: 1.0, green: 0.55, blue: 0.3, alpha: 1.0)
        let longRayShape = CGSize(width: 2, height: 28)
        for angle in stride(from: CGFloat(0), to: .pi * 2, by: .pi / 4) {
            let ray = SKSpriteNode(color: rayColor, size: longRayShape)
            ray.blendMode = .add
            ray.alpha = 0.9
            ray.zRotation = angle
            container.addChild(ray)
        }

        let coreColor = SKColor(red: 1.0, green: 0.8, blue: 0.55, alpha: 1.0)
        let core = SKSpriteNode(color: coreColor, size: CGSize(width: 4, height: 4))
        core.blendMode = .add
        container.addChild(core)

        let pulse = SKAction.sequence([
            SKAction.group([
                SKAction.scale(to: 1.4, duration: 0.28),
                SKAction.fadeAlpha(to: 1.0, duration: 0.28),
            ]),
            SKAction.group([
                SKAction.scale(to: 0.7, duration: 0.28),
                SKAction.fadeAlpha(to: 0.55, duration: 0.28),
            ]),
        ])
        container.run(SKAction.repeatForever(pulse))
        container.run(SKAction.repeatForever(
            SKAction.rotate(byAngle: .pi / 2, duration: 0.9)
        ))

        container.run(SKAction.sequence([
            .wait(forDuration: duration),
            .removeFromParent(),
        ]))
        return container
    }

    /// One-shot bright flash used when OverdriveAttack commits to firing.
    /// Mirrors Godot `flash.gd` with a warm ember tint to contrast the intro's
    /// cooler violet. Short (0.25s) and scales horizontally so it reads as a
    /// recoil burst from the cannon mouth.
    static func cannonFireFlash(at point: CGPoint, facing: Facing) -> SKNode {
        if let tex = EffectAtlases.animation(.light)?.textures.first {
            let node = SKSpriteNode(texture: tex, size: CGSize(width: 128, height: 128))
            node.position = point
            node.zPosition = 59
            node.alpha = 0.85
            node.blendMode = .add
            node.colorBlendFactor = 1.0
            node.color = .white
            node.xScale = facing.sign * 1.25
            let targetColor = SKColor(red: 1.0, green: 0.45, blue: 0.2, alpha: 1.0)
            let tween = SKAction.group([
                SKAction.colorize(with: targetColor, colorBlendFactor: 1.0, duration: 0.25),
                SKAction.fadeOut(withDuration: 0.25),
                SKAction.scaleX(to: facing.sign * 3.0, duration: 0.25),
                SKAction.scaleY(to: 0.5, duration: 0.25),
            ])
            node.run(SKAction.sequence([tween, .removeFromParent()]))
            return node
        }

        let node = SKSpriteNode(color: .white, size: CGSize(width: 160, height: 80))
        node.position = point
        node.zPosition = 59
        node.alpha = 0.8
        node.colorBlendFactor = 1.0
        node.xScale = facing.sign

        let targetColor = SKColor(red: 1.0, green: 0.45, blue: 0.2, alpha: 1.0)
        let tween = SKAction.group([
            SKAction.colorize(with: targetColor, colorBlendFactor: 1.0, duration: 0.25),
            SKAction.fadeOut(withDuration: 0.25),
            SKAction.scaleX(to: facing.sign * 3.0, duration: 0.25),
            SKAction.scaleY(to: 0.4, duration: 0.25),
        ])
        node.run(SKAction.sequence([tween, .removeFromParent()]))
        return node
    }

    /// One pulse of the boss-death barrage — orange ring + violet sparks
    /// scattered ~24 px outward over 0.45 s. Matches the visual cadence of
    /// Godot's BossDeath.gd `explosions.emitting = true` (continuous Smoke +
    /// Explosion particle bursts during the 10 s explosion_time). Without a
    /// particle system we synthesize each pulse as a self-removing SKNode
    /// so the scene can schedule them at the same ~0.45 s cadence.
    static func bossDeathBurst(at point: CGPoint) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 60

        // Bright orange flash — half-second pulse fading to violet, mirrors
        // the explosion sprite's hot core.
        let flash = SKSpriteNode(
            color: SKColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1.0),
            size: CGSize(width: 28, height: 28)
        )
        flash.blendMode = .add
        flash.colorBlendFactor = 1.0
        let flashTween = SKAction.group([
            SKAction.colorize(
                with: SKColor(red: 0.9, green: 0.55, blue: 1.0, alpha: 1.0),
                colorBlendFactor: 1.0,
                duration: 0.45
            ),
            SKAction.fadeOut(withDuration: 0.45),
            SKAction.scale(to: 1.6, duration: 0.45),
        ])
        flash.run(SKAction.sequence([flashTween, .removeFromParent()]))
        container.addChild(flash)

        // Outward shrapnel — 8 small particles in a ring.
        let sparkColor = SKColor(red: 1.0, green: 0.92, blue: 0.6, alpha: 1.0)
        for i in 0..<8 {
            let angle = CGFloat(i) * (.pi * 2 / 8) + CGFloat.random(in: -0.18...0.18)
            let distance: CGFloat = 22 + CGFloat.random(in: -4...10)
            let p = SKSpriteNode(color: sparkColor, size: CGSize(width: 3, height: 3))
            p.blendMode = .add
            let move = SKAction.moveBy(x: cos(angle) * distance, y: sin(angle) * distance, duration: 0.5)
            let fade = SKAction.fadeOut(withDuration: 0.5)
            p.run(SKAction.sequence([SKAction.group([move, fade]), .removeFromParent()]))
            container.addChild(p)
        }

        container.run(SKAction.sequence([.wait(forDuration: 0.55), .removeFromParent()]))
        return container
    }

    /// Full-screen white flash for the final beat of BossDeath. Mirrors
    /// Godot `Event.emit_signal("boss_death_screen_flash")` which the HUD
    /// reads as a momentary white wash before the fade-to-black handoff.
    static func bossDeathScreenFlash(stageSize: CGSize) -> SKNode {
        let node = SKSpriteNode(color: SKColor.white, size: stageSize)
        node.anchorPoint = .zero
        node.position = .zero
        node.zPosition = 305
        node.alpha = 0
        let pulse = SKAction.sequence([
            SKAction.fadeAlpha(to: 1.0, duration: 0.08),
            SKAction.wait(forDuration: 0.05),
            SKAction.fadeAlpha(to: 0, duration: 0.4),
            .removeFromParent(),
        ])
        node.run(pulse)
        return node
    }

    /// Lance overlay composite — adds trail sprites + firetip + evilfire
    /// children to the supplied Projectile node. Mirrors the visible nodes in
    /// `Lance.tscn`:
    ///   - `trail`, `trail2`, `trail3`, `trail4` AnimatedSprite2D using
    ///     sigma_trail.png; positioned at fixed offsets along the lance's
    ///     local +Y axis (which after the lance's `zRotation = atan2(v) + π`
    ///     points BACK along the throw direction). Each fades in with a
    ///     0.03 s stagger to approximate the Godot `activate_trail` Tools.timer_p
    ///     calls (Lance.gd:21-26) that build the throw-streak illusion.
    ///   - `firetip` GPUParticles2D using sigma_particles2.png as a 3×3 anim;
    ///     spawned periodically near the spear tip with a slight outward
    ///     drift (matches Godot direction Vector3(0.5, -1, 0), spread 16°).
    ///   - `evilfire_particles` GPUParticles2D using sigma_particles.png;
    ///     drifting upward sparks along the spear shaft (Godot gravity
    ///     Vector3(0, -20, 0) → upward in screen space).
    /// All overlays are children of the lance, so they freeze automatically
    /// when the lance embeds and self-remove with the lance.
    static func attachLanceOverlays(to lance: Projectile) {
        // The Swift lance rotates with `zRotation = atan2(bdx, -bdy)` where
        // bdx/bdy = impact - boss, which makes Swift lance-local +Y point
        // TOWARD BOSS in world (the TAIL side). Godot's `look_at(boss) + 90°`
        // makes its lance-local -Y point toward boss in its Y-down frame.
        // → Godot Y values flip sign when ported to Swift.
        //
        // Trails: Godot Y = -64 / -126 / -186 / -252 (toward-boss in Godot)
        // → Swift Y = +64 / +126 / +186 / +252 (toward-boss in Swift).
        // Each trail texture is 160×21 (wide horizontal); after rotation its
        // long axis spans Swift lance-local ±X = perpendicular to the throw
        // axis in world — the cross-hatch streak Lance.tscn renders.
        //
        // Lance.gd:21-26 activates trails FAR-first (trail_4 → trail_3 →
        // trail_2 → trail) with 0.01 + 0.03·i timing, so the deepest layer
        // fades in first and the streak pulls back toward the spear tip.
        // Each trail plays once with loop=false in Godot and holds the final
        // frame.
        //
        // hide_far_trails (Lance.gd:28-35): if |dx| AND |dy| < 170 px, hide
        // trail_3 and trail_4; if both < 280, hide trail_4.
        let distance = lance.lanceDistanceFromOrigin
        let hideIndices: Set<Int>
        if distance < 170 {
            hideIndices = [2, 3]   // hide trail_3 (i=2) and trail_4 (i=3)
        } else if distance < 280 {
            hideIndices = [3]      // hide trail_4 only
        } else {
            hideIndices = []
        }

        if let trail = EffectAtlases.animation(.sigmaTrail) {
            let trailSize = CGSize(width: 160, height: 21)
            let staggerStep: TimeInterval = 0.03
            // Per-trail positions: Godot Y [-64, -126, -186, -252] flipped
            // to Swift +Y (toward boss).
            let trailYs: [CGFloat] = [64, 126, 186, 252]
            for i in 0..<4 where !hideIndices.contains(i) {
                let sprite = SKSpriteNode(texture: trail.textures.first, size: trailSize)
                sprite.position = CGPoint(x: 0, y: trailYs[i])
                sprite.zPosition = -0.05  // behind lance art
                sprite.alpha = 0
                sprite.blendMode = .add
                let animate = SKAction.animate(with: trail.textures, timePerFrame: trail.timePerFrame)
                sprite.run(SKAction.sequence([
                    .wait(forDuration: 0.01 + Double(3 - i) * staggerStep),
                    .fadeIn(withDuration: 0.05),
                    animate,
                ]))
                lance.addChild(sprite)
            }
        }

        // Particle emitters. Godot Lance.gd state 1 → 2 (timer > 2s) calls
        // `firetip.emitting = false` and `fire.emitting = false` to stop new
        // particles. Hook a stop closure on the projectile so its tick can
        // cancel the spawn loops at the matching moment.
        let firetipEmitter = SKNode()
        let evilfireEmitter = SKNode()
        let stopKey = "lance-spawn-loop"

        // Firetip — animated 3×3 atlas spawning near the spear tip every
        // ~0.1 s. Godot lifetime 0.5 s, amount 6 (≈0.083 s apart). Godot
        // emitter at (1, -2) → Swift (1, +2). Drift Godot direction (0.5, -1)
        // → Swift (0.5, +1) so particles drift toward boss along Swift +Y.
        if let firetip = EffectAtlases.animation(.sigmaParticleAnim) {
            firetipEmitter.position = CGPoint(x: 1, y: 2)
            firetipEmitter.zPosition = 0.2
            let spawn = SKAction.run { [weak firetipEmitter] in
                guard let firetipEmitter else { return }
                let p = SKSpriteNode(texture: firetip.textures.first, size: CGSize(width: 16, height: 16))
                p.blendMode = .add
                p.alpha = 0.95
                let drift = SKAction.moveBy(
                    x: CGFloat.random(in: -2...2) + 3,
                    y: CGFloat.random(in: 4...12),
                    duration: 0.5
                )
                let animate = SKAction.animate(with: firetip.textures, timePerFrame: firetip.timePerFrame)
                p.run(SKAction.sequence([
                    SKAction.group([drift, animate, .fadeOut(withDuration: 0.5)]),
                    .removeFromParent(),
                ]))
                firetipEmitter.addChild(p)
            }
            firetipEmitter.run(SKAction.repeatForever(SKAction.sequence([
                spawn,
                .wait(forDuration: 0.1),
            ])), withKey: stopKey)
            lance.addChild(firetipEmitter)
        }

        // Evilfire — purple sparks drifting along the shaft. Godot
        // evilfire_particles at (0, -49) → Swift (0, +49). Godot gravity
        // (0, -20, 0) drifts UP in Y-down world; mapped to Swift +Y drift
        // (toward boss along the shaft).
        if let evilfire = EffectAtlases.animation(.sigmaParticle) {
            evilfireEmitter.position = CGPoint(x: 0, y: 49)
            evilfireEmitter.zPosition = -0.1
            let spawn = SKAction.run { [weak evilfireEmitter] in
                guard let evilfireEmitter else { return }
                let p = SKSpriteNode(texture: evilfire.textures.first, size: CGSize(width: 12, height: 12))
                p.blendMode = .add
                p.color = SKColor(red: 0.9, green: 0.4, blue: 1.0, alpha: 1.0)
                p.colorBlendFactor = 0.4
                p.alpha = 0.85
                p.position = CGPoint(x: CGFloat.random(in: -2...2), y: 0)
                let drift = SKAction.moveBy(
                    x: CGFloat.random(in: -3...3),
                    y: CGFloat.random(in: 12...22),
                    duration: 0.5
                )
                p.run(SKAction.sequence([
                    SKAction.group([drift, .fadeOut(withDuration: 0.5), .scale(to: 0.4, duration: 0.5)]),
                    .removeFromParent(),
                ]))
                evilfireEmitter.addChild(p)
            }
            evilfireEmitter.run(SKAction.repeatForever(SKAction.sequence([
                spawn,
                .wait(forDuration: 0.07),
            ])), withKey: stopKey)
            lance.addChild(evilfireEmitter)
        }

        // Stop callback — invoked from Projectile.tick at lanceStateTimer ≥ 2s
        // (mirrors Lance.gd state 1 → 2 transition where firetip + evilfire
        // emitting flags are set false). Removing the spawn action stops new
        // particles; existing particles fade out via their own SKActions.
        lance.onLanceParticleStop = { [weak firetipEmitter, weak evilfireEmitter] in
            firetipEmitter?.removeAction(forKey: stopKey)
            evilfireEmitter?.removeAction(forKey: stopKey)
        }
    }

    /// Short-lived debris burst where the throne used to stand. Scatters
    /// ~12 small dark-violet particles outward + upward and fades them.
    static func throneExplosion(at point: CGPoint) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 45

        let particleColor = SKColor(red: 0.35, green: 0.18, blue: 0.28, alpha: 1.0)
        for i in 0..<12 {
            let p = SKSpriteNode(color: particleColor, size: CGSize(width: 5, height: 5))
            let angle = CGFloat(i) * (.pi * 2 / 12) + CGFloat.random(in: -0.2...0.2)
            let distance: CGFloat = 40 + CGFloat.random(in: -8...18)
            let dx = cos(angle) * distance
            let dy = abs(sin(angle)) * distance * 0.7 + 8
            let move = SKAction.moveBy(x: dx, y: dy, duration: 0.5)
            let fade = SKAction.fadeOut(withDuration: 0.5)
            let shrink = SKAction.scale(to: 0.3, duration: 0.5)
            p.run(SKAction.sequence([SKAction.group([move, fade, shrink]), .removeFromParent()]))
            container.addChild(p)
        }
        container.run(SKAction.sequence([.wait(forDuration: 0.6), .removeFromParent()]))
        return container
    }
}
