import Foundation
import OpenSpriteKit

// MARK: - Player (Mega Man X)
// Source: Mega-Man-X8-16-bit/src/Actors/Player.gd + Modules/Movement.gd, Walk.gd, Jump.gd, Dash.gd

enum PlayerState: String, CaseIterable {
    case idle, walkStart, walk, jump, fall, dash, airDash, slide, wallJump, hurt, dead, victory
}

@MainActor
final class Player: Actor {
    private(set) var state: PlayerState = .idle
    private var dashTimer: TimeInterval = 0
    private var shootCooldown: TimeInterval = 0
    private var shotPoseTimer: TimeInterval = 0
    private var shotPoseIsStrong: Bool = false
    private var walkStartTimer: TimeInterval = 0
    private var jumpHoldTimer: TimeInterval = 0
    private var isJumpHeld: Bool = false
    private var airDashTimer: TimeInterval = 0
    private var hasAirDashedThisJump: Bool = false
    private var wallJumpTimer: TimeInterval = 0
    // Godot WallSlide.gd start_delay (0.16 s). Tracks how long the player has
    // been in the .slide state so the slide-speed clamp engages only after
    // the wall-grab settle window.
    private var wallSlideTimer: TimeInterval = 0
    private var hurtTimer: TimeInterval = 0
    // Knockback direction sign captured at takeDamage time. Godot Damage._Setup
    // stores it once via define_knockback_direction(inflicter); _Update keeps
    // re-applying horizontal_velocity * stored_sign each tick, so flipping
    // facing mid-stagger does NOT rotate the recoil. Keep the sign sticky for
    // the duration of the hurt state.
    private var hurtKnockbackSign: CGFloat = 1
    private var wallContact: Facing?
    private(set) var chargeLevel: Int = 0  // 0=none, 1=mid, 2=full
    private var chargeTimer: TimeInterval = 0
    private var prevShootHeld: Bool = false

    // Death sequence. Mirrors Godot PlayerDeath.gd timing:
    //   t=0.0   — _Setup: pause game, health=0, deactivate character
    //   t>0.5   — unpause, hide sprite, emit explosions
    //   t>1.5   — fade-out begins (scene reads deathSequenceElapsed for fade)
    //   t>5.0   — GameManager.on_death() equivalent (scene handles restart/game_over)
    private var deathTimer: TimeInterval = 0
    private var deathSequenceBegun: Bool = false
    private var deathSecondBurstFired: Bool = false
    /// Time elapsed in the current death sequence. Scene polls this to drive
    /// fade overlay + restart trigger without Player knowing about phases.
    var deathSequenceElapsed: TimeInterval { deathTimer }
    var isDead: Bool { state == .dead }

    // Charge halo child node, swapped when charge level changes. Mirrors
    // Godot Charge.gd ChargingParticle / ChargedParticle visibility toggles.
    private var chargeHaloNode: SKNode?
    private var chargeHaloLevel: Int = -1
    // Atlases for the charge overlay (Godot charge_1.png / charge_2.png).
    // Indexed by charge level; nil entries fall back to the colored halo.
    private var chargeAtlases: [Int: SpriteAtlas] = [:]

    // Dash ghost spawn timer — emits a fading sprite snapshot every tick.
    private var dashGhostTimer: TimeInterval = 0

    // Display sprite is 64x56 from the Aseprite atlas; logical hitbox matches
    // Godot `x_collision_box.tres` (Vector2(13.99, 30)). The narrow body is
    // why X visually clears doorframes and presses flush against walls in the
    // reference game — anything wider produces a gap and breaks walljump reach.
    static let bodySize = CGSize(width: 14, height: 30)
    static let spriteSize = CGSize(width: 64, height: 56)
    // The idle frame's bottom-most opaque pixel sits 8px above the frame's bottom
    // edge (measured against x.png). Shift the visual down so the character's
    // feet line up with the actor's position instead of the frame padding.
    static let spriteFootOffset: CGFloat = -8

    weak var battleScene: BossBattleScene?

    private let visual: SKSpriteNode
    private var atlas: SpriteAtlas?
    private var currentAnimationTag: String?

    init() {
        // Visual child renders the actual character sprite.
        // Anchored at (0.5, 0) so its feet sit on the actor's foot point.
        visual = SKSpriteNode(color: SKColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1.0),
                              size: Player.spriteSize)
        visual.anchorPoint = CGPoint(x: 0.5, y: 0)
        visual.position = CGPoint(x: 0, y: Player.spriteFootOffset)
        visual.zPosition = 0.1
        visual.colorBlendFactor = 1.0

        // The Actor's own colored quad is invisible — visuals come from `visual`.
        super.init(color: .clear, size: Player.bodySize, maxHealth: PhysicsConstants.playerMaxHealth)
        self.anchorPoint = CGPoint(x: 0.5, y: 0)
        self.zPosition = 50
        self.colorBlendFactor = 0
        addChild(visual)
    }

    // MARK: - Atlas

    func attachAtlas(_ atlas: SpriteAtlas) {
        self.atlas = atlas
        // Drop the placeholder color tint once real textures are bound.
        visual.colorBlendFactor = 0
        playAnimation("idle", repeating: true)
    }

    /// Register the atlas backing the charge-level overlay. Level 1 maps to
    /// Godot `charge_1.png` (mid charge), level 2 to `charge_2.png` (full).
    /// If the overlay is currently visible, rebuild it so the atlas takes
    /// effect immediately.
    func attachChargeAtlas(_ atlas: SpriteAtlas, for level: Int) {
        chargeAtlases[level] = atlas
        if chargeHaloLevel == level {
            chargeHaloLevel = -1
            updateChargeHalo()
        }
    }

    private func playAnimation(_ tag: String, repeating: Bool = true) {
        guard let atlas, currentAnimationTag != tag else { return }
        guard let anim = atlas.animation(tag) else {
            // Fallback to idle if a missing tag is requested.
            if tag != "idle" { playAnimation("idle", repeating: true) }
            return
        }
        currentAnimationTag = tag
        visual.removeAction(forKey: "anim")
        // Set first frame eagerly so the visual reflects the requested tag even
        // when the scene is paused (no SKAction tick will run to advance it).
        visual.texture = anim.textures[0]
        if anim.textures.count == 1 { return }
        let action = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
        let runner = repeating ? SKAction.repeatForever(action) : action
        visual.run(runner, withKey: "anim")
    }

    // MARK: - Tick

    func tick(_ dt: TimeInterval, input: InputManager, stageWidth: CGFloat, floorY: CGFloat) {
        advance(dt)

        // Cooldowns
        shootCooldown = max(0, shootCooldown - dt)

        // Mirrors Godot `character.deactivate()` in PlayerDeath._Setup:
        // `listening_to_inputs = false` gates Charge._Update / Shot._Update,
        // so dead/victory frames stop accepting input. Physics still settle
        // (disable_floor_snap + position pinning in Godot) — here we just
        // integrate the frozen body so clampToStage keeps it in bounds.
        if state == .dead || state == .victory {
            prevShootHeld = false
            if state == .dead { tickDeathSequence(dt) }
            applyGravity(dt)
            integrate(dt)
            clampToStage(width: stageWidth, floorY: floorY)
            tickFloorTimer(dt)
            updateVisual()
            return
        }

        // Charge — accumulates while shoot held. Thresholds match Godot Charge.gd
        // (minimum_charge_time=0.5, level_3_charge=1.75). Level 3 (arm_cannon.upgraded)
        // is out of scope for the Sigma battle, so we cap at 2.
        if input.shoot {
            chargeTimer += dt
            if chargeTimer > WeaponConstants.chargeFullThreshold { chargeLevel = 2 }
            else if chargeTimer > WeaponConstants.chargeMidThreshold { chargeLevel = 1 }
            else { chargeLevel = 0 }
        }
        // Release edge — fire a charged shot only if we reached at least level 1.
        // Godot Charge.gd: releasing before minimum_charge_time calls EndAbility
        // (no shot); the uncharged "lemon" is fired by Shot.gd on press-edge, not
        // release. Mirroring that split prevents the double-fire that made rapid
        // tapping feel like a semi-auto machine gun.
        if !input.shoot && prevShootHeld && chargeLevel >= 1 && shootCooldown <= 0 && state != .dash && state != .airDash {
            shoot()
        }
        prevShootHeld = input.shoot
        updateChargeHalo()

        switch state {
        case .idle, .walkStart, .walk, .jump, .fall:
            handleMovement(dt, input: input)
        case .dash:
            handleDash(dt, input: input)
        case .airDash:
            handleAirDash(dt, input: input)
        case .slide:
            handleSlide(dt, input: input)
        case .wallJump:
            handleWallJump(dt, input: input)
        case .hurt:
            // Godot Damage.gd: knockback ends after duration_time (0.6s) OR on
            // wall-collision with matching input direction. Invulnerability
            // outlasts the hurt state by ~1.15s (1.75 - 0.6), handled by the
            // Actor invulnerability timer independently of state.
            hurtTimer -= dt
            velocity.dx = hurtKnockbackSign * PhysicsConstants.hurtKnockbackX
            if hurtTimer <= 0 {
                state = onFloor ? .idle : .fall
            }
        case .dead, .victory:
            // Unreachable — early return above short-circuits these states.
            break
        }

        // Edge-triggered shoot (uncharged tap) — fire immediately if not charging.
        if input.shootPressed && shootCooldown <= 0 && state != .dash && state != .airDash && chargeLevel == 0 {
            shoot()
        }

        // Tick shot pose overlay timer.
        if shotPoseTimer > 0 { shotPoseTimer = max(0, shotPoseTimer - dt) }
        if walkStartTimer > 0 { walkStartTimer = max(0, walkStartTimer - dt) }

        applyGravity(dt)
        integrate(dt)
        clampToStage(width: stageWidth, floorY: floorY)
        tickFloorTimer(dt)
        updateWallContact(stageWidth: stageWidth)

        // Reset air-dash one-shot when grounded again.
        if onFloor { hasAirDashedThisJump = false }

        // Resolve state after physics
        if onFloor {
            if state == .jump || state == .fall || state == .airDash {
                state = abs(velocity.dx) > 1 ? enterWalk() : .idle
            } else if state == .idle && abs(velocity.dx) > 1 {
                state = enterWalk()
            } else if state == .walkStart && walkStartTimer <= 0 {
                state = abs(velocity.dx) > 1 ? .walk : .idle
            } else if state == .walk && abs(velocity.dx) < 1 {
                state = .idle
            }
        } else if state == .jump && velocity.dy <= 0 {
            state = .fall
        }
        updateWallSlide(input: input)

        updateVisual()
    }

    // MARK: - Movement

    private func handleMovement(_ dt: TimeInterval, input: InputManager) {
        // Horizontal input
        let horizontal: CGFloat = (input.right ? 1 : 0) - (input.left ? 1 : 0)
        if horizontal != 0 {
            let desired: Facing = horizontal > 0 ? .right : .left
            if desired != facing {
                // Godot reference: direction change flips facing immediately and
                // the walk animation restarts from walk_start. No separate "turn"
                // animation plays (the "turn" atlas tag is bike/attack-specific).
                face(desired)
                if onFloor && (state == .idle || state == .walk || state == .walkStart) {
                    state = .walkStart
                    walkStartTimer = 0.09  // ~2 frames at atlas 44ms + small buffer
                }
            }
            // Godot Walk._Update: when starting_from_stop (last ability == Idle)
            // the first 0.08 s applies horizontal_velocity / 4 (22.5 px/s) to
            // ramp the player out of a standing start; afterwards full
            // horizontal_velocity. Swift's `state == .walkStart` is the
            // analogue of starting_from_stop, and `walkStartTimer` decreases
            // from 0.09 → 0 (~one walk_start frame) — using the remaining
            // window to gate the ramp keeps us within ~10 % of Godot timing
            // without a parallel timer.
            let rampActive = state == .walkStart && walkStartTimer > 0.01
            let speed = rampActive
                ? PhysicsConstants.playerWalkSpeed / 4
                : PhysicsConstants.playerWalkSpeed
            velocity.dx = horizontal * speed
        } else {
            velocity.dx = 0
        }

        // Dash
        if input.dashPressed {
            if onFloor {
                startDash(direction: facing)
                return
            } else if !hasAirDashedThisJump {
                startAirDash(direction: facing)
                return
            }
        }

        // Jump — supports variable-height jump (holding extends upward velocity).
        if input.jumpPressed && onFloor {
            velocity.dy = PhysicsConstants.playerJumpVelocity
            onFloor = false
            state = .jump
            jumpHoldTimer = 0
            isJumpHeld = true
        }

        if state == .jump {
            // Replicates Godot Jump.gd ascent curve: brief full-velocity phase
            // followed by a slowdown-to-zero curve. Without this, the naive
            // "hold raises velocity floor" approach lets the player hover too
            // long and roughly doubles the max jump height.
            if isJumpHeld && input.jump {
                jumpHoldTimer += dt
                let fullspeedEnd = PhysicsConstants.playerJumpMaxTime * PhysicsConstants.playerJumpFullspeedProportion
                let slowdownWindow = PhysicsConstants.playerJumpMaxTime - fullspeedEnd
                if jumpHoldTimer < fullspeedEnd {
                    velocity.dy = PhysicsConstants.playerJumpVelocity
                } else {
                    let slowdownT = jumpHoldTimer - fullspeedEnd
                    let sv = slowdownWindow - slowdownT / slowdownWindow
                    if sv > 0 {
                        velocity.dy = PhysicsConstants.playerJumpVelocity * sv
                    } else {
                        // Slowdown exhausted — let gravity take over.
                        isJumpHeld = false
                    }
                }
                if jumpHoldTimer >= PhysicsConstants.playerJumpMaxTime {
                    isJumpHeld = false
                }
            } else if !input.jump && velocity.dy > 0 {
                // Release during ascent: cut upward velocity (Jump.gd if_no_input_zero_vertical_speed).
                velocity.dy = 0
                isJumpHeld = false
            }
        }
    }

    // MARK: - Dash / AirDash

    private func startDash(direction: Facing) {
        state = .dash
        dashTimer = PhysicsConstants.playerDashDuration
        velocity.dx = direction.sign * PhysicsConstants.playerDashSpeed
        dashGhostTimer = 0
        spawnDashDust(trailingSign: -direction.sign)
    }

    private func handleDash(_ dt: TimeInterval, input: InputManager) {
        dashTimer -= dt
        velocity.dx = facing.sign * PhysicsConstants.playerDashSpeed
        dashGhostTimer -= dt
        if dashGhostTimer <= 0 {
            spawnDashGhost()
            dashGhostTimer = 0.04
        }
        // Mid-dash jump cancel
        if input.jumpPressed && onFloor {
            velocity.dy = PhysicsConstants.playerJumpVelocity
            state = .jump
            onFloor = false
            jumpHoldTimer = 0
            isJumpHeld = true
            return
        }
        // Leaving the floor mid-dash converts to a fall and preserves horizontal
        // momentum (Godot Dash: _EndCondition returns false off-floor, then Fall
        // reads character.dashfall to keep 210 px/s instead of 90).
        if !onFloor {
            state = .fall
            return
        }
        let pressingOpposite = (facing == .right && input.left && !input.right)
                            || (facing == .left && input.right && !input.left)
        if !input.dash || pressingOpposite || dashTimer <= 0 {
            velocity.dx = 0
            state = .idle
        }
    }

    private func startAirDash(direction: Facing) {
        state = .airDash
        airDashTimer = PhysicsConstants.playerAirDashDuration
        hasAirDashedThisJump = true
        velocity.dx = direction.sign * PhysicsConstants.playerDashSpeed
        velocity.dy = 0  // X8 air-dash freezes vertical motion briefly
        gravityScale = 0
        dashGhostTimer = 0
        spawnAirJumpPuff()
    }

    private func handleAirDash(_ dt: TimeInterval, input: InputManager) {
        airDashTimer -= dt
        velocity.dx = facing.sign * PhysicsConstants.playerDashSpeed
        dashGhostTimer -= dt
        if dashGhostTimer <= 0 {
            spawnDashGhost()
            dashGhostTimer = 0.04
        }
        if airDashTimer <= 0 {
            gravityScale = 1
            velocity.dx = 0
            state = onFloor ? .idle : .fall
        }
    }

    // MARK: - Walk helpers

    /// Transition into walk, inserting a brief walk_start frame when coming from idle.
    private func enterWalk() -> PlayerState {
        if state == .idle {
            walkStartTimer = 0.09
            return .walkStart
        }
        return .walk
    }

    // MARK: - Wall slide / Wall jump

    private func handleSlide(_ dt: TimeInterval, input: InputManager) {
        // While sliding we descend at Godot's WallSlide rate. Press jump to
        // wall-jump away. Godot WallSlide.gd:
        //   - During start_delay (0.16 s) the body is held against the wall
        //     and vy is NOT capped (gravity continues).
        //   - After start_delay, `set_vertical_speed(jump_velocity)` ASSIGNS
        //     velocity.y = 90 (Player.tscn override), Y-up port → -90.
        //     Assignment, not clamp — the player decelerates from whatever
        //     gravity produced during start_delay into the slow controlled
        //     slide.
        // Drop out of slide if the player lifts off the wall key — Godot
        // Wallslide _EndCondition: "Not pressing towards wall" / "Not pressing".
        let pressingIntoWall = (wallContact == .left && input.left)
                            || (wallContact == .right && input.right)
        guard let wallContact, pressingIntoWall else {
            state = onFloor ? .idle : .fall
            return
        }
        // Godot Wallslide.gd:_Setup `set_direction(- get_pressed_direction())`
        // — slide animation faces AWAY from the wall, so X visually presses his
        // back/side against the wall.
        face(wallContact.opposite)
        wallSlideTimer += dt
        if wallSlideTimer > WallSlideConstants.startDelay {
            velocity.dy = -WallSlideConstants.slideSpeed
        }
        if input.jumpPressed {
            startWallJump()
            return
        }
        if onFloor {
            state = .idle
        }
    }

    private func startWallJump() {
        // Wall contact side is the direction the player is still facing before
        // the flip. Spawn dust against that wall.
        let wallSide = wallContact ?? facing
        spawnWallDust(wallSign: wallSide.sign)
        state = .wallJump
        // Godot Walljump.gd:_Setup zeroes both velocity components and gates
        // motion behind a 0.116 s `start_delay` (process_gravity / ascent /
        // set_movement_and_direction all skip until delay_has_expired). That
        // produces a perceptible 7-frame freeze on press where the player is
        // glued to the wall — the SNES original launches instantly, and the
        // freeze made the port read as "wall jump doesn't work" because input
        // had no immediate visible response.
        //
        // Skip the lock and launch on the same frame instead. Players still
        // see the walljump animation play, and the resulting trajectory
        // (jump_velocity up + move_away_speed out) matches what the Godot
        // port would have produced after delay expiry.
        let walljumpDir: CGFloat = -wallSide.sign
        // Godot Walljump.gd:_Setup `set_direction(- walljump_direction)` — kick
        // pose faces TOWARD the wall while the body launches away. Visually X
        // arches outward with his front to the wall.
        face(wallSide)
        velocity.dx = walljumpDir * WallJumpConstants.moveAwaySpeed
        velocity.dy = PhysicsConstants.playerJumpVelocity
        onFloor = false
        position.x += 2 * walljumpDir
        position.y += 2  // Godot `position.y -= 2` is upward; Y-up port adds.
        wallJumpTimer = 0
        wallContact = nil
    }

    private func handleWallJump(_ dt: TimeInterval, input: InputManager) {
        wallJumpTimer += dt
        let moveAwayEnd = WallJumpConstants.moveAwayDuration
        // facing was set to point TOWARD the wall in startWallJump (kick pose),
        // so the launch direction is the negation of facing.sign.
        let awaySign: CGFloat = -facing.sign
        if wallJumpTimer < moveAwayEnd {
            // Phase B — drift away from wall at move_away_speed while
            // Jump.gd's slowdown ascent runs.
            velocity.dx = awaySign * WallJumpConstants.moveAwaySpeed
            applyJumpAscent(dt, jumpHoldTimerOverride: wallJumpTimer)
        } else {
            // Phase C — full Jump.gd behaviour. Walking input from this
            // point governs horizontal motion just like a regular jump.
            let horizontal: CGFloat = (input.right ? 1 : 0) - (input.left ? 1 : 0)
            velocity.dx = horizontal != 0
                ? horizontal * PhysicsConstants.playerWalkSpeed
                : awaySign * WallJumpConstants.moveAwaySpeed
            applyJumpAscent(dt, jumpHoldTimerOverride: wallJumpTimer)
        }

        // Godot Walljump._EndCondition: after timer > 0.05 + start_delay,
        // if facing a wall again and falling, end. With the lock removed the
        // 0.05 s grace alone is enough to keep the state alive through the
        // initial frames before normal gravity inversion is detected.
        if wallJumpTimer > 0.05 {
            if velocity.dy <= 0 {
                state = .fall
            }
        }
    }

    /// Apply Jump.gd's slowdown-ascent curve using an externally tracked
    /// ascent timer. Used by WallJump phase B/C so the same easing applies
    /// without depending on `jumpHoldTimer` (which is reserved for normal
    /// `.jump` state and gates input.jump to extend).
    private func applyJumpAscent(_ dt: TimeInterval, jumpHoldTimerOverride: TimeInterval) {
        let fullspeedEnd = PhysicsConstants.playerJumpMaxTime * PhysicsConstants.playerJumpFullspeedProportion
        let slowdownWindow = PhysicsConstants.playerJumpMaxTime - fullspeedEnd
        let t = jumpHoldTimerOverride
        if t < fullspeedEnd {
            velocity.dy = PhysicsConstants.playerJumpVelocity
        } else {
            let slowdownT = t - fullspeedEnd
            let sv = slowdownWindow - slowdownT / slowdownWindow
            if sv > 0 {
                velocity.dy = PhysicsConstants.playerJumpVelocity * sv
            }
        }
    }

    private func updateWallContact(stageWidth: CGFloat) {
        let halfW = size.width / 2
        let epsilon: CGFloat = 0.5
        if position.x <= halfW + epsilon {
            wallContact = .left
        } else if position.x >= stageWidth - halfW - epsilon {
            wallContact = .right
        } else if let wallHit = battleScene?.sigmaWallContact(for: hitbox) {
            // After Intro stage 4 the SigmaWall pillars stand inside the arena;
            // resolveCollisions snaps the player to a wall's inner edge but
            // doesn't itself register contact for slide / wall-jump. Pull the
            // contact side from the scene so the same wallContact pipeline
            // that handles stage borders also fires off the pillars.
            wallContact = wallHit
        } else {
            wallContact = nil
        }
    }

    private func updateWallSlide(input: InputManager) {
        // Godot WallSlide.conflicting_moves = ["WallJump", "DashWallJump",
        // "Walk"] — WallSlide can interrupt WallJump on contact with a wall.
        // Without `.wallJump` in the source set, the chain "kick off wall →
        // fly to opposite wall → re-slide" never re-arms.
        guard !onFloor,
              state == .jump || state == .fall || state == .airDash || state == .wallJump,
              let wallContact else { return }
        // Godot WallSlide._StartCondition: `character.get_vertical_speed() > 0`
        // (falling, in Y-down). Y-up port → require descending velocity, so
        // the rising phase of a jump cannot snap into a slide on contact.
        guard velocity.dy < 0 else { return }
        let pressingIntoWall = (wallContact == .left && input.left)
                            || (wallContact == .right && input.right)
        guard pressingIntoWall else { return }
        gravityScale = 1
        velocity.dx = 0
        // Don't zero-clamp vy here — Godot lets gravity continue accumulating
        // during the start_delay window. The slideSpeed clamp engages in
        // handleSlide once wallSlideTimer exceeds startDelay.
        wallSlideTimer = 0
        state = .slide
        // Match Godot Wallslide.gd: facing AWAY from the wall during slide so
        // the sprite presses its back/side against the surface. Set on entry
        // to avoid a 1-frame flicker before handleSlide repeats it.
        face(wallContact.opposite)
    }

    // MARK: - Shoot

    private func shoot() {
        guard let scene = battleScene else { return }
        shootCooldown = 0.2
        // Muzzle Y matches the arm-cannon pixel on the X sprite (64×56 frame,
        // anchor bottom-center, foot offset -8). Gun pixel sits at ~55% of frame.
        let baseMuzzleY = position.y + Player.spriteFootOffset + Player.spriteSize.height * 0.55
        // The 64×64 heavy_shot frame is bigger than the lemon/medium frames, so
        // centering it at the gun Y makes the ball graphic appear to drop below
        // the arm cannon. Lift charged shots by 8 px so the ball sits on the
        // gun muzzle instead of below it.
        let muzzleY = chargeLevel >= 2 ? baseMuzzleY + 8 : baseMuzzleY
        let muzzle = CGPoint(x: position.x + facing.sign * (size.width / 2 + 4),
                             y: muzzleY)
        // Godot Buster.tscn shots array: [Lemon, Medium Buster, Charged Buster] indexed by charge_level.
        scene.spawnPlayerShot(chargeLevel: chargeLevel, from: muzzle, facing: facing)
        // Brief upper-body shot pose overlay. Uses shot_strong atlas tag for charge 2+.
        shotPoseIsStrong = chargeLevel >= 2
        shotPoseTimer = shotPoseIsStrong ? 0.18 : 0.12
        chargeLevel = 0
        chargeTimer = 0
    }

    // MARK: - Effects

    /// Swap the charge halo child when the charge level changes.
    /// Level 0 → remove. Level 1/2 → bind the matching charge atlas if one is
    /// loaded; otherwise fall back to a synthetic colored halo.
    private func updateChargeHalo() {
        guard chargeLevel != chargeHaloLevel else { return }
        chargeHaloNode?.removeFromParent()
        chargeHaloNode = nil
        chargeHaloLevel = chargeLevel
        if chargeLevel == 0 { return }
        let halo: SKNode
        if let atlas = chargeAtlases[chargeLevel] {
            halo = PlayerEffects.chargeOverlay(atlas: atlas, level: chargeLevel)
        } else {
            halo = PlayerEffects.chargeHalo(level: chargeLevel)
        }
        // Center on sprite's mid-body. visual anchor is (0.5, 0) at
        // spriteFootOffset, so body-center y ≈ bodySize.height / 2.
        halo.position = CGPoint(x: 0, y: Player.bodySize.height / 2)
        addChild(halo)
        chargeHaloNode = halo
    }

    private func spawnDashDust(trailingSign: CGFloat) {
        guard let scene = battleScene else { return }
        let puff = PlayerEffects.dustPuff(
            at: CGPoint(x: position.x + trailingSign * 6, y: position.y + 2),
            color: SKColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 0.95),
            spread: 14
        )
        scene.addChild(puff)
    }

    private func spawnWallDust(wallSign: CGFloat) {
        guard let scene = battleScene else { return }
        let puff = PlayerEffects.dustPuff(
            at: CGPoint(x: position.x + wallSign * (size.width / 2),
                        y: position.y + Player.bodySize.height * 0.4),
            color: SKColor(red: 0.82, green: 0.82, blue: 0.85, alpha: 0.9),
            spread: 10
        )
        scene.addChild(puff)
    }

    private func spawnDashGhost() {
        guard let scene = battleScene else { return }
        if let ghost = PlayerEffects.ghost(
            texture: visual.texture,
            size: Player.spriteSize,
            at: position,
            facingSign: facing.sign,
            yOffset: Player.spriteFootOffset
        ) {
            scene.addChild(ghost)
        }
    }

    private func spawnAirJumpPuff() {
        guard let scene = battleScene else { return }
        let puff = PlayerEffects.airJumpPuff(
            at: CGPoint(x: position.x, y: position.y + 2)
        )
        scene.addChild(puff)
    }

    private func spawnDamageSpark() {
        guard let scene = battleScene else { return }
        let spark = PlayerEffects.damageSpark(
            at: CGPoint(x: position.x, y: position.y + Player.bodySize.height / 2)
        )
        scene.addChild(spark)
    }

    /// Brief white tint on the sprite — mirrors Godot `character.flash()`,
    /// which flashes the animatedSprite pure white for a single frame on hit.
    /// The Actor base class only applies an alpha drop; this adds the color
    /// punch on top so hits read clearly over invulnerability blink.
    private func flashWhite() {
        visual.removeAction(forKey: "flash")
        let flash = SKAction.sequence([
            SKAction.run { [visual] in
                visual.color = SKColor.white
                visual.colorBlendFactor = 1.0
            },
            SKAction.wait(forDuration: PhysicsConstants.damageFlashDuration),
            SKAction.run { [visual] in
                visual.colorBlendFactor = 0
            }
        ])
        visual.run(flash, withKey: "flash")
    }

    private func spawnDeathExplosion() {
        guard let scene = battleScene else { return }
        let boom = PlayerEffects.deathExplosion(
            at: CGPoint(x: position.x, y: position.y + Player.bodySize.height / 2)
        )
        scene.addChild(boom)
    }

    /// Enter the death sequence. Godot PlayerDeath._Setup freezes the
    /// character and pauses the game for 0.5s *before* hiding the sprite or
    /// emitting explosions — the staged visuals happen in `tickDeathSequence`.
    /// Here we only record the transition + reset the timer.
    private func die() {
        guard state != .dead else { return }
        state = .dead
        velocity = .zero
        gravityScale = 0
        chargeLevel = 0
        chargeTimer = 0
        // Drop any active charge halo so the explosion isn't visually polluted.
        chargeHaloNode?.removeFromParent()
        chargeHaloNode = nil
        chargeHaloLevel = -1
        deathTimer = 0
        deathSequenceBegun = false
        deathSecondBurstFired = false
    }

    /// Advances the staged Godot PlayerDeath sequence. Called once per tick
    /// while `state == .dead`. Scene is responsible for the fade-out overlay
    /// and the post-5s restart/game-over transition; this function only owns
    /// the character-visible side (sprite hide + scripted 2-round burst).
    ///
    /// Godot `Player Death.gd` emits exactly two 8-particle rounds — the
    /// first on `emit()` and the second 0.45 s later via `second_round_delay`
    /// — and does NOT re-emit after that. Both rounds use the same 8
    /// compass-direction materials, giving an X-pattern that pulses twice.
    private func tickDeathSequence(_ dt: TimeInterval) {
        deathTimer += dt
        if !deathSequenceBegun && deathTimer >= 0.5 {
            deathSequenceBegun = true
            // Godot PlayerDeath._physics_process (timer > 0.5):
            //   animatedSprite.visible = false; explosions.emit_effect()
            visual.isHidden = true
            spawnDeathExplosion()
            return
        }
        guard deathSequenceBegun, !deathSecondBurstFired else { return }
        // Godot `Player Death.gd._process`: `second_round_delay = 0.45` is set
        // when `emit()` runs, then decremented each frame; when it crosses zero
        // the second 8-particle round emits exactly once. Fire at t = 0.95.
        if deathTimer >= 0.5 + 0.45 {
            deathSecondBurstFired = true
            spawnDeathExplosion()
        }
    }

    /// Restore the player to a freshly-spawned state at `point`. Used when
    /// Godot `GameManager.on_death()` → `restart_level` runs after the death
    /// fade completes. Clears every transient state so the next battle is
    /// indistinguishable from a first-time load.
    func respawn(at point: CGPoint) {
        position = point
        velocity = .zero
        gravityScale = 1
        onFloor = true
        state = .idle
        visual.isHidden = false
        // Actor.heal saturates at maxHealth; explicit amount is safe even if
        // currentHealth was reduced to 0 by the prior death.
        heal(maxHealth)
        face(.right)
        deathTimer = 0
        deathSequenceBegun = false
        deathSecondBurstFired = false
        hurtTimer = 0
        dashTimer = 0
        airDashTimer = 0
        walkStartTimer = 0
        wallJumpTimer = 0
        shootCooldown = 0
        shotPoseTimer = 0
        jumpHoldTimer = 0
        isJumpHeld = false
        hasAirDashedThisJump = false
        wallContact = nil
        prevShootHeld = false
        chargeLevel = 0
        chargeTimer = 0
        chargeHaloNode?.removeFromParent()
        chargeHaloNode = nil
        chargeHaloLevel = -1
        currentAnimationTag = nil
        updateVisual()
    }

    // MARK: - Visuals

    private func updateVisual() {
        // Shot pose overlay briefly overrides grounded idle/walk visuals while firing.
        if shotPoseTimer > 0 && (state == .idle || state == .walk || state == .walkStart) {
            playAnimation(shotPoseIsStrong ? "shot_strong" : "shot", repeating: false)
            return
        }

        let tag: String
        let repeating: Bool
        switch state {
        case .idle:         (tag, repeating) = ("idle", true)
        case .walkStart:    (tag, repeating) = ("walk_start", false)
        case .walk:         (tag, repeating) = ("walk", true)
        case .jump:         (tag, repeating) = ("jump", false)
        case .fall:         (tag, repeating) = ("fall", false)
        case .dash:         (tag, repeating) = ("dash", false)
        case .airDash:      (tag, repeating) = ("airdash", false)
        case .slide:        (tag, repeating) = ("slide", false)
        case .wallJump:     (tag, repeating) = ("walljump", false)
        case .hurt:         (tag, repeating) = ("damage", false)
        case .dead:         return  // Sprite is hidden; explosion carries the visual.
        case .victory:      (tag, repeating) = ("victory", false)
        }
        playAnimation(tag, repeating: repeating)
    }

    // MARK: - Damage

    override func takeDamage(_ amount: CGFloat, inflicterX: CGFloat? = nil) -> Bool {
        let applied = super.takeDamage(amount, inflicterX: inflicterX)
        if applied {
            // Godot Damage.gd _Setup: set_vertical_speed(-jump_velocity) and
            // set_horizontal_velocity(define_knockback_direction(inflicter) *
            // horizontal_velocity). Movement.gd defaults supply
            // jump_velocity = 320 / horizontal_velocity = 90, and
            // define_knockback_direction returns +1 if actor.x > inflicter.x
            // else -1 — i.e. pushed AWAY from the source, not opposite facing.
            // Y-up port: Godot's `-jump_velocity` (upward) → +hurtKnockbackY.
            // When inflicter is unknown (test harness, contact-only paths)
            // fall back to "opposite of current facing" so the player still
            // recoils visibly.
            let dir: CGFloat
            if let ix = inflicterX {
                dir = (position.x - ix) >= 0 ? 1 : -1
            } else {
                dir = -facing.sign
            }
            hurtKnockbackSign = dir
            // Godot Damage._Setup: `set_direction(-damage_direction)` — face
            // TOWARD the inflicter while the body is knocked away, so the
            // hurt animation reads as a recoil rather than a stagger-flee.
            face(dir > 0 ? .left : .right)
            velocity.dx = dir * PhysicsConstants.hurtKnockbackX
            velocity.dy = PhysicsConstants.hurtKnockbackY
            onFloor = false
            hurtTimer = PhysicsConstants.hurtDuration
            // If damage interrupts an air-dash (or any state that zeroed gravity),
            // restore gravityScale — otherwise the player floats indefinitely.
            gravityScale = 1
            airDashTimer = 0
            dashTimer = 0
            chargeLevel = 0
            chargeTimer = 0
            spawnDamageSpark()
            flashWhite()
            if !isAlive {
                die()
            } else {
                state = .hurt
            }
        }
        return applied
    }

    /// Enter the victory pose. Mirrors Godot `Event.emit_signal("player_pose")`
    /// which the player listens for at boss-death time to halt input and play
    /// the `victory` animation tag. The early-return in `tick(_:input:...)`
    /// freezes input the same way `character.deactivate()` does in Godot.
    func enterVictoryPose() {
        guard state != .dead else { return }
        state = .victory
        velocity = .zero
        gravityScale = onFloor ? 0 : 1
        chargeLevel = 0
        chargeTimer = 0
        chargeHaloNode?.removeFromParent()
        chargeHaloNode = nil
        chargeHaloLevel = -1
        currentAnimationTag = nil
        updateVisual()
    }

    // MARK: - Hitbox

    var hitbox: CGRect {
        CGRect(x: position.x - size.width / 2, y: position.y, width: size.width, height: size.height)
    }

    // MARK: - Test Harness

    /// Force a state transition for screenshot verification. Leaves physics frozen so the sprite stays put.
    func debugForce(state: PlayerState, facing: Facing? = nil) {
        if let facing { face(facing) }
        self.state = state
        velocity = .zero
        gravityScale = 0
        switch state {
        case .dash:         dashTimer = 999
        case .airDash:      airDashTimer = 999
        case .walkStart:    walkStartTimer = 999
        case .wallJump:     wallJumpTimer = 999
        default:            break
        }
        updateVisual()
    }

    func debugRelease() {
        gravityScale = 1
        dashTimer = 0
        airDashTimer = 0
        walkStartTimer = 0
        wallJumpTimer = 0
        shotPoseTimer = 0
        state = onFloor ? .idle : .fall
        updateVisual()
    }

    /// Test-harness hook that mirrors the natural death flow without needing
    /// to drain HP via contact damage. Applies a lethal takeDamage so the
    /// normal `die()` transition runs and `tickDeathSequence` ticks on
    /// subsequent frames. Used by `death_explosion.spec.ts` to assert
    /// sparkle animation without the ~15 s wait for Sigma contact damage.
    func debugKill() {
        _ = takeDamage(.greatestFiniteMagnitude)
    }
}
