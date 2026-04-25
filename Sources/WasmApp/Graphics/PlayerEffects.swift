import Foundation
import OpenSpriteKit

// MARK: - PlayerEffects
// Transient / persistent visual effects for Player actions. Source:
// Mega-Man-X8-16-bit/src/Actors/Player scene tree + Dash.gd + Charge.gd +
// trail.gd. Godot composes the character visual from AnimatedSprite2D +
// particle children + shader overlay + Line2D trail; OpenSpriteKit has no
// SKEmitterNode path we rely on here, so each layer is reconstructed from
// plain SKSpriteNode + SKAction.

@MainActor
enum PlayerEffects {

    // MARK: - Dust puff
    // Used for dash start and wall-kick contact. Renders the Godot `smoke.png`
    // 3x3 sprite sheet once in place, matching the Walk.gd / WallJump dust
    // animation. Falls back to a compound puff of shrinking particles during
    // the brief window before the atlas finishes loading at boot.
    static func dustPuff(at point: CGPoint,
                         color: SKColor = SKColor(white: 0.85, alpha: 1.0),
                         spread: CGFloat = 12) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 45

        if let anim = EffectAtlases.animation(.smoke), let first = anim.textures.first {
            let scale = spread / 10.0
            let sprite = SKSpriteNode(texture: first, size: CGSize(width: 16 * scale, height: 16 * scale))
            sprite.colorBlendFactor = 0
            let play = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
            sprite.run(SKAction.sequence([play, .removeFromParent()]))
            container.addChild(sprite)
            container.run(SKAction.sequence([.wait(forDuration: anim.duration + 0.05), .removeFromParent()]))
            return container
        }

        for i in 0..<5 {
            let p = SKSpriteNode(color: color, size: CGSize(width: 3, height: 3))
            let angle = CGFloat(i) * (.pi * 2 / 5) + CGFloat.random(in: -0.3...0.3)
            let distance: CGFloat = spread + CGFloat.random(in: -3...5)
            let dx = cos(angle) * distance
            let dy = abs(sin(angle)) * distance * 0.6
            let move = SKAction.moveBy(x: dx, y: dy, duration: 0.3)
            let fade = SKAction.fadeOut(withDuration: 0.3)
            let shrink = SKAction.scale(to: 0.4, duration: 0.3)
            p.run(SKAction.sequence([SKAction.group([move, fade, shrink]), .removeFromParent()]))
            container.addChild(p)
        }
        container.run(SKAction.sequence([.wait(forDuration: 0.4), .removeFromParent()]))
        return container
    }

    // MARK: - Ghost sprite (dash trail)
    // Snapshot of the current player texture, fading out in place. Mirrors
    // Godot Dash.gd `duringImage` ghost-sprite effect.
    static func ghost(texture: SKTexture?,
                      size: CGSize,
                      at point: CGPoint,
                      facingSign: CGFloat,
                      yOffset: CGFloat) -> SKNode? {
        guard let texture else { return nil }
        let ghost = SKSpriteNode(texture: texture, size: size)
        ghost.anchorPoint = CGPoint(x: 0.5, y: 0)
        ghost.position = CGPoint(x: point.x, y: point.y + yOffset)
        ghost.xScale = facingSign
        ghost.alpha = 0.55
        ghost.colorBlendFactor = 0.7
        ghost.color = SKColor(red: 0.35, green: 0.8, blue: 1.0, alpha: 1.0)
        ghost.zPosition = 48
        let fade = SKAction.fadeOut(withDuration: 0.22)
        ghost.run(SKAction.sequence([fade, .removeFromParent()]))
        return ghost
    }

    // MARK: - Charge halo (parented to player)
    // Two-tier aura matching Godot ChargingParticle / ChargedParticle visibility
    // toggles in Charge.gd. Level 1 = mid (blue-cyan); Level 2 = full (amber).
    // Returned node is intended to live as a child of the Player node, centred
    // on its body centre (see `chargeHaloCenter(for:)`).
    static func chargeHalo(level: Int) -> SKNode {
        let container = SKNode()
        // Above the visual child (z = 0.1) so the halo draws in front of the
        // character — matching Godot, where ChargingParticle's effective z is
        // higher than AnimatedSprite2D's via z_as_relative stacking.
        container.zPosition = 0.2

        let color: SKColor
        let radius: CGFloat
        let particleCount: Int
        let size: CGFloat
        let orbitDuration: TimeInterval

        switch level {
        case 3:
            // SuperCharge (arm_cannon.upgraded) — Godot SuperChargeParticle
            // (x_supercharged_particle.tres). Larger violet-white ring, faster orbit.
            color = SKColor(red: 0.95, green: 0.7, blue: 1.0, alpha: 1.0)
            radius = 28
            particleCount = 10
            size = 5
            orbitDuration = 0.4
        case 2:
            color = SKColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 1.0)
            radius = 22
            particleCount = 8
            size = 4
            orbitDuration = 0.55
        default:
            color = SKColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1.0)
            radius = 16
            particleCount = 6
            size = 3
            orbitDuration = 0.75
        }

        for i in 0..<particleCount {
            let p = SKSpriteNode(color: color, size: CGSize(width: size, height: size))
            let angleStart = CGFloat(i) * (.pi * 2 / CGFloat(particleCount))
            p.position = CGPoint(x: cos(angleStart) * radius, y: sin(angleStart) * radius)
            container.addChild(p)

            let orbit = SKAction.customAction(withDuration: orbitDuration) { node, t in
                let angle = angleStart + (CGFloat(t) / CGFloat(orbitDuration)) * .pi * 2
                node.position = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            p.run(SKAction.repeatForever(orbit))

            let pulse = SKAction.sequence([
                SKAction.fadeAlpha(to: 0.35, duration: 0.18),
                SKAction.fadeAlpha(to: 1.0, duration: 0.18)
            ])
            p.run(SKAction.repeatForever(pulse))
        }

        // Soft inner glow — single larger low-alpha sprite pulses size.
        let glow = SKSpriteNode(color: color, size: CGSize(width: radius * 1.6, height: radius * 1.6))
        glow.alpha = 0.22
        glow.zPosition = -0.02
        container.addChild(glow)
        glow.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.scale(to: 1.15, duration: 0.3),
            SKAction.scale(to: 0.85, duration: 0.3)
        ])))

        return container
    }

    // MARK: - Charge overlay (Aseprite atlas)
    // Godot `ChargingParticle` / `ChargedParticle` drive `charge_1.png` /
    // `charge_2.png` through a GPUParticles2D with `particles_anim_loop=false`,
    // so a single particle plays the 4x4 frame sheet once before respawning.
    // OpenSpriteKit has no particle path here, so we render a single persistent
    // sprite that loops the atlas — close enough for the charge tell.
    static func chargeOverlay(atlas: SpriteAtlas, level: Int) -> SKNode {
        let size: CGFloat = level == 2 ? 56 : 44
        let sprite = SKSpriteNode(texture: nil, size: CGSize(width: size, height: size))
        sprite.zPosition = 0.2      // Above the player's visual child (z = 0.1).
        sprite.blendMode = .add     // Additive — matches Godot's CanvasItemMaterial default for fire-type overlays.
        sprite.alpha = 0.9

        if let anim = atlas.animation("loop") ?? atlas.animations.first?.value {
            sprite.texture = anim.textures.first
            if anim.textures.count > 1 {
                let action = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
                sprite.run(SKAction.repeatForever(action), withKey: "anim")
            }
        }
        return sprite
    }

    // MARK: - Damage spark
    // Plays Godot `sparks.png` (3x2 sheet, Damage.tscn `sparks` AnimatedSprite2D)
    // once at the hit point. Falls back to a radial burst of additive shards
    // during the pre-load window.
    static func damageSpark(at point: CGPoint) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 60

        if let anim = EffectAtlases.animation(.sparks), let first = anim.textures.first {
            let sprite = SKSpriteNode(texture: first, size: CGSize(width: 24, height: 24))
            sprite.blendMode = .add
            let play = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
            sprite.run(SKAction.sequence([play, .removeFromParent()]))
            container.addChild(sprite)
            container.run(SKAction.sequence([.wait(forDuration: anim.duration + 0.05), .removeFromParent()]))
            return container
        }

        let core = SKSpriteNode(color: SKColor(white: 1.0, alpha: 1.0),
                                size: CGSize(width: 10, height: 10))
        core.blendMode = .add
        core.alpha = 0.95
        core.run(SKAction.sequence([
            SKAction.group([
                SKAction.scale(to: 2.2, duration: 0.12),
                SKAction.fadeOut(withDuration: 0.18)
            ]),
            .removeFromParent()
        ]))
        container.addChild(core)

        let shardCount = 8
        for i in 0..<shardCount {
            let shard = SKSpriteNode(color: SKColor(red: 1.0, green: 1.0, blue: 0.85, alpha: 1.0),
                                     size: CGSize(width: 3, height: 3))
            shard.blendMode = .add
            let angle = CGFloat(i) * (.pi * 2 / CGFloat(shardCount)) + CGFloat.random(in: -0.1...0.1)
            let distance: CGFloat = 16 + CGFloat.random(in: 0...6)
            let dx = cos(angle) * distance
            let dy = sin(angle) * distance
            let move = SKAction.moveBy(x: dx, y: dy, duration: 0.22)
            let fade = SKAction.fadeOut(withDuration: 0.22)
            let shrink = SKAction.scale(to: 0.35, duration: 0.22)
            shard.run(SKAction.sequence([
                SKAction.group([move, fade, shrink]),
                .removeFromParent()
            ]))
            container.addChild(shard)
        }

        container.run(SKAction.sequence([.wait(forDuration: 0.3), .removeFromParent()]))
        return container
    }

    // MARK: - Death explosion
    // Mirrors Godot `X Death Particles` scene (src/Effects/Player Death.tscn):
    // 8 GPUParticles2D nodes emit a single particle each along one of the 8
    // compass directions, forming the X-shaped burst of Mega Man X's death.
    // Per-particle direction vectors come from xdeath_0..xdeath_8 materials
    // (Godot `direction = Vector3(...)`), Y-flipped into SpriteKit Y-up:
    //
    //   xdeath_0  ( 1,  0) → right            SpriteKit ( 1,  0)
    //   xdeath_1  ( 1,  1) → down-right       SpriteKit ( 1, -1)
    //   xdeath_3  ( 0,  1) → down             SpriteKit ( 0, -1)
    //   xdeath_4  (-1,  1) → down-left        SpriteKit (-1, -1)
    //   xdeath_5  (-1,  0) → left             SpriteKit (-1,  0)
    //   xdeath_6  (-1, -1) → up-left          SpriteKit (-1,  1)
    //   xdeath_7  ( 1, -1) → up-right         SpriteKit ( 1,  1)
    //   xdeath_8  ( 0, -1) → up               SpriteKit ( 0,  1)
    //
    // Each particle uses death.png (3x2 sprite sheet of a blue burst) with
    // particles_anim_loop=true over Godot's default 1 s lifetime. Without the
    // atlas bound here we stand in with a bright cyan disc that expands and
    // fades — preserving the X-shape silhouette without the frame sequence.
    // Godot's scene has NO fullscreen light flash inside X Death Particles —
    // the full-viewport fade is owned by `background_light` in PlayerDeath.gd
    // and is driven by BossBattleScene.updateDefeatFade, not by this node.
    private static let deathBurstDirections: [CGVector] = [
        CGVector(dx:  1, dy:  0),
        CGVector(dx:  1, dy: -1),
        CGVector(dx:  0, dy: -1),
        CGVector(dx: -1, dy: -1),
        CGVector(dx: -1, dy:  0),
        CGVector(dx: -1, dy:  1),
        CGVector(dx:  1, dy:  1),
        CGVector(dx:  0, dy:  1),
    ]

    // One sparkle frame of the X-death burst. Godot `xdeath_0..8.tres` drive
    // death.png (3x2 blue-burst sheet) with `particles_anim_loop=true` — so
    // each particle plays the full 6-frame cycle across its ~1 s lifetime.
    // Falls back to a procedural starburst during the pre-load window.
    private static func makeDeathSparkle() -> SKNode {
        if let anim = EffectAtlases.animation(.death), let first = anim.textures.first {
            let sprite = SKSpriteNode(texture: first, size: CGSize(width: 20, height: 20))
            sprite.blendMode = .add
            // Slow the Godot 6-frame cycle to roughly match the ~1 s lifetime.
            let slowPerFrame: TimeInterval = 1.0 / TimeInterval(anim.textures.count)
            sprite.run(SKAction.repeatForever(
                SKAction.animate(with: anim.textures, timePerFrame: slowPerFrame)
            ))
            return sprite
        }

        let sparkle = SKNode()

        let rayColor = SKColor(red: 0.82, green: 0.96, blue: 1.0, alpha: 1.0)
        let longRay = CGSize(width: 2, height: 26)
        let vertical = SKSpriteNode(color: rayColor, size: longRay)
        vertical.blendMode = .add
        sparkle.addChild(vertical)

        let horizontal = SKSpriteNode(color: rayColor, size: CGSize(width: longRay.height, height: longRay.width))
        horizontal.blendMode = .add
        sparkle.addChild(horizontal)

        let diagColor = SKColor(red: 0.6, green: 0.9, blue: 1.0, alpha: 1.0)
        let shortRay = CGSize(width: 2, height: 14)
        for angle in stride(from: CGFloat.pi / 4, to: .pi * 2, by: .pi / 2) {
            let diag = SKSpriteNode(color: diagColor, size: shortRay)
            diag.blendMode = .add
            diag.alpha = 0.8
            diag.zRotation = angle
            sparkle.addChild(diag)
        }

        let core = SKSpriteNode(color: SKColor(white: 1.0, alpha: 1.0),
                                size: CGSize(width: 5, height: 5))
        core.blendMode = .add
        sparkle.addChild(core)

        return sparkle
    }

    static func deathExplosion(at point: CGPoint) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 70

        // Per-particle travel distance over its ~1s lifetime. Godot's xdeath
        // materials don't set initial_velocity, so pixel speed is the engine
        // default — the X-shape needs to read across most of the arena's
        // height (224 px stage), so each particle spreads 80 px outward.
        let radius: CGFloat = 80
        let lifetime: TimeInterval = 1.0

        for dir in deathBurstDirections {
            let sparkle = makeDeathSparkle()
            sparkle.position = .zero
            sparkle.setScale(0.2)
            sparkle.alpha = 0.0

            // Normalize diagonals so each direction travels an equal radius.
            let length = max(0.0001, sqrt(dir.dx * dir.dx + dir.dy * dir.dy))
            let dx = (dir.dx / length) * radius
            let dy = (dir.dy / length) * radius

            // Scale sequence mimics the 6 frames of death.png: frames 1-3 grow
            // from tiny spark → peak starburst, frames 4-6 shrink back to a
            // fading glow. Full-rotation spin adds the twinkling sparkle feel.
            let growIn = SKAction.scale(to: 1.6, duration: lifetime * 0.35)
            growIn.timingMode = .easeOut
            let hold = SKAction.scale(to: 1.2, duration: lifetime * 0.25)
            let shrink = SKAction.scale(to: 0.25, duration: lifetime * 0.4)
            shrink.timingMode = .easeIn

            let move = SKAction.moveBy(x: dx, y: dy, duration: lifetime)
            move.timingMode = .easeOut

            // Fade curve: quick pop-in to full opacity, held through peak,
            // then fades alongside the shrink. Avoids the peak-scale frame
            // being half-transparent.
            let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: lifetime * 0.15)
            let alphaHold = SKAction.fadeAlpha(to: 1.0, duration: lifetime * 0.45)
            let fadeOut = SKAction.fadeOut(withDuration: lifetime * 0.4)

            let spin = SKAction.rotate(byAngle: .pi, duration: lifetime)

            sparkle.run(SKAction.sequence([
                SKAction.group([
                    move,
                    spin,
                    SKAction.sequence([fadeIn, alphaHold, fadeOut]),
                    SKAction.sequence([growIn, hold, shrink])
                ]),
                .removeFromParent()
            ]))
            container.addChild(sparkle)
        }

        container.run(SKAction.sequence([.wait(forDuration: lifetime + 0.1), .removeFromParent()]))
        return container
    }

    // MARK: - Air-dash puff
    // Plays Godot `airdash.png` (3x2 sheet, AirDash.gd kick-off) once under
    // the character. Falls back to a compact compound puff during the pre-load
    // window.
    static func airJumpPuff(at point: CGPoint) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 45

        if let anim = EffectAtlases.animation(.airdash), let first = anim.textures.first {
            let sprite = SKSpriteNode(texture: first, size: CGSize(width: 32, height: 32))
            let play = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
            sprite.run(SKAction.sequence([play, .removeFromParent()]))
            container.addChild(sprite)
            container.run(SKAction.sequence([.wait(forDuration: anim.duration + 0.05), .removeFromParent()]))
            return container
        }

        for i in 0..<4 {
            let p = SKSpriteNode(color: SKColor(white: 0.9, alpha: 0.9),
                                 size: CGSize(width: 3, height: 3))
            let angle = .pi + CGFloat(i) * (.pi / 3) - .pi / 3 + CGFloat.random(in: -0.2...0.2)
            let distance: CGFloat = 8 + CGFloat.random(in: 0...4)
            let dx = cos(angle) * distance
            let dy = sin(angle) * distance * 0.5
            let move = SKAction.moveBy(x: dx, y: dy, duration: 0.22)
            let fade = SKAction.fadeOut(withDuration: 0.22)
            let shrink = SKAction.scale(to: 0.5, duration: 0.22)
            p.run(SKAction.sequence([
                SKAction.group([move, fade, shrink]),
                .removeFromParent()
            ]))
            container.addChild(p)
        }
        container.run(SKAction.sequence([.wait(forDuration: 0.3), .removeFromParent()]))
        return container
    }
}
