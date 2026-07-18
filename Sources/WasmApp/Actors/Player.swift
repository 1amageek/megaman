import Foundation
import OpenSpriteKit

// MARK: - Player (Mega Man X)
// Source: Mega-Man-X8-16-bit/src/Actors/Player.gd + Modules/Movement.gd, Walk.gd, Jump.gd, Dash.gd

enum PlayerState: String, CaseIterable {
    case idle, walkStart, walk, jump, fall, dash, airDash, slide, wallJump,
         hurt, dead, victory, beamIn,
         talk, armorReceive, armorBlink, damageResist, rideStop, rideStopEnd,
         crouch, crouchTalk, balance, counter, punchDown,
         stairsStart, stairs, stairsEnd,
         aimShotRight, aimShotLeft, aimShotUp
}

// MARK: - Player.Action API
// Public action vocabulary. Each case maps 1:1 to one Aseprite tag in
// `Public/assets/sprites/x/x.json` and declares (via `Player.actionSpecs`)
// the particles and overlays Godot's `Player.tscn` attaches at the matching
// ability stage. This is the SINGLE SOURCE OF TRUTH for:
//   - which Aseprite tag plays
//   - whether the tag loops or freezes on the last frame (Godot SpriteFrames
//     `loop=true/false`, mirrored from `play_animation` vs `play_animation_once`)
//   - what VFX the action emits (one-shot on start + continuous while active)
//
// Both the state machine (this file) and the harness (`forcePlayerAction`)
// consume this enum. Adding a new ability means: add a case here + add a row
// in `actionSpecs` — nothing else.
extension Player {
    enum Action: String, CaseIterable, Sendable {
        // Idle / walk
        case idle, idleWeak, walkStart, walk, turn
        // Air / movement
        case jump, fall
        // Dash / wall
        case dash, airDash, slide, wallJump
        // Shoot poses (over-frame upper-body overlay on Idle/Walk)
        case shot, shotStrong, shotRecover, recover
        case shotRight, shotLeft, shotUp
        // Damage / death
        case damage, damageResist
        case dead
        // Beam-in / armor
        case beam, beamIn, beamArmor
        case armorReceive, armorBlink
        // Misc
        case victory
        case crouch, crouchTalk, talk
        case counter, punchDown
        case stairsStart, stairs, stairsEnd
        case balance
        case rideStop, rideStopEnd
    }

    // MARK: - Player.VFX
    // Thin handle into `PlayerEffects.swift` factory functions. The Player
    // tick translates each spec into an `SKNode` spawn at the right scene
    // anchor (feet / wall-contact / body-center). Anchors are resolved in
    // `spawnVFX(_:)` below using the live Player state (position, facing,
    // wallContact, sprite size).
    enum VFX: Sendable {
        /// One-shot smoke puff at feet, pushed `behind` the facing direction.
        /// Source: Godot `Dash Smoke Particles` (Player.tscn:328) at
        /// (-10, +18) on animatedSprite → (-10, +14) root, 1 px above feet.
        case dustBehindFeet(spread: CGFloat)
        /// One-shot smoke puff at the wall-contact pixel, low-shin height.
        /// Source: Godot `WallSlide Particles` (Player.tscn:342) at
        /// (-14, +11) on animatedSprite → (-14, +7) root, 8 px above feet.
        case dustAtWallContact(spread: CGFloat)
        /// One-shot smoke puff at the wall-kick foot — distinct from the
        /// slide puff because it sits 6 px lower (at the foot push-off
        /// pixel). Source: Godot `WallJump Particle` (Player.tscn:356) at
        /// (+14, +17) on animatedSprite → (+14, +13) root, 2 px above feet.
        case dustAtWallKick(spread: CGFloat)
        /// Ground-dash streak overlay (dash.png 3×2). Godot `Dash/dash_particle`
        /// Sprite2D (Player.tscn:1023) at (-22, 0) on the Dash node, mirrored
        /// via SpriteEffect.gd `_particle.scale.x = scale_x`. Distinct from
        /// `dustBehindFeet` (smoke); both fire on the same dash entry.
        case dashStreak
        /// Air-dash streak overlay (airdash.png 3×2). Godot
        /// `AirDash/dash_particle` Sprite2D (Player.tscn:886) at (-16, +4) on
        /// the AirDash node, mirrored via SpriteEffect.gd. AirDash overrides
        /// `emit_particles` to no-op, so this is the ONLY VFX it emits.
        case airDashStreak
        /// Damage spark above the body. Godot `Damage/sparks`
        /// AnimatedSprite (Player.tscn:609) at (0, -8) on the Damage
        /// node → 8 px above root center, 23 px above feet.
        case damageSpark
        /// 8-direction X-shaped death burst at body center.
        /// Godot `X Death Particles` (Player Death.tscn).
        case deathBurst
    }

    // MARK: - Player.ActionSpec
    // Declarative per-Action effect bundle. `onStart` fires once on action
    // entry; `continuous` re-emits each entry's VFX every `interval` seconds
    // while the action is active. `loops=true` mirrors Godot's SpriteFrames
    // `loop` flag — the Aseprite JSON has no loop hint so this table is the
    // ground truth.
    struct ActionSpec: Sendable {
        let tag: String?
        let loops: Bool
        let onStart: [VFX]
        let continuous: [(VFX, TimeInterval)]

        init(tag: String?, loops: Bool,
             onStart: [VFX] = [],
             continuous: [(VFX, TimeInterval)] = []) {
            self.tag = tag
            self.loops = loops
            self.onStart = onStart
            self.continuous = continuous
        }
    }

    // MARK: - actionSpecs (single source of truth)
    // Every Player.Action case has a row here. Empty `onStart`/`continuous`
    // means "animation-only, no VFX." When porting a Godot ability, the
    // particle wiring belongs HERE, not scattered in the imperative `start*`
    // / `handle*` methods — those just call `applyOnStartVFX(_:)` /
    // `tickContinuousVFX(_:dt:)`.
    static let actionSpecs: [Action: ActionSpec] = [
        // Idle / walk — pure animation, no VFX.
        .idle:        ActionSpec(tag: "idle",        loops: true),
        .idleWeak:    ActionSpec(tag: "weak",        loops: true),
        .walkStart:   ActionSpec(tag: "walk_start",  loops: false),
        .walk:        ActionSpec(tag: "walk",        loops: true),
        // `turn` exists in x.json (210-214) but is BIKE-only in Godot —
        // keep the row so the table stays exhaustive against the enum.
        .turn:        ActionSpec(tag: "turn",        loops: false),

        // Jump / fall — Godot doesn't attach particles to these.
        // `fall` does NOT loop (verified against Player.swift call-sites
        // and the player-preview TAG_LOOP table).
        .jump:        ActionSpec(tag: "jump",        loops: false),
        .fall:        ActionSpec(tag: "fall",        loops: false),

        // Dash — Godot Dash.gd:
        //   _Setup    → Dash Smoke Particles emitting=true (smoke, amount=11/lifetime=0.75)
        //   _Update   → process_invulnerability() syncs duringImage / ghost_particle,
        //               but BOTH are gated on `upgraded and invulnerability_duration > 0`
        //               (Dash.invulnerable). Player.tscn's Dash node leaves both at the
        //               defaults (upgraded=false, invulnerability_duration=0), so the
        //               ghost overlay is INACTIVE for fresh-spawn / Sigma-v1 X.
        // OpenSpriteKit therefore emits only the smoke; ghost trails would
        // diverge from upstream (and from player-preview parity).
        .dash:        ActionSpec(
            tag: "dash", loops: false,
            onStart:    [.dustBehindFeet(spread: 14), .dashStreak],
            continuous: [(.dustBehindFeet(spread: 14), 0.09)]
        ),

        // AirDash — Godot AirDash.gd:81-83 EXPLICITLY overrides
        // `emit_particles()` with an empty body, so NO dash-smoke. The
        // kick-off uses airdash.png (3x2 frame burst) once. The ghost
        // overlay is also inactive for the same upgraded/invulnerability
        // gate as Dash above.
        //
        // Player tag is `"dash"` (frames 88-91 — horizontal forward pose),
        // NOT `"airdash"` (frames 163-165). Per Godot Player.tscn:874 the
        // AirDash node sets `animation = "dash"`, reusing the ground-dash
        // pose. The `"airdash"` tag in x.json is an unused upward pose —
        // no Godot script or scene references it, and rendering it here
        // produced an upward-leaning X with horizontal dash particles
        // (visible mismatch between body orientation and trail direction).
        .airDash:     ActionSpec(
            tag: "dash", loops: false,
            onStart:    [.airDashStreak]
        ),

        // WallSlide — Godot Wallslide.gd:_Update emits WallSlide Particles
        // (smoke, amount=6/lifetime=0.55) every frame after start_delay (0.16s).
        // Throttle to 0.12s in the Swift handler — see handleSlide.
        .slide:       ActionSpec(
            tag: "slide", loops: false,
            continuous: [(.dustAtWallContact(spread: 10), 0.12)]
        ),

        // WallJump — Godot Walljump.gd:_Setup `particles.emitting=true` on
        // the WallJump Particle (one-shot, 0.03s lifetime). The kick puff
        // sits 6 px LOWER than the slide puff (Player.tscn 17 vs 11 on
        // animatedSprite — i.e. at the foot push-off pixel, not the
        // hip-rub pixel), so it has its own VFX case rather than reusing
        // dustAtWallContact.
        .wallJump:    ActionSpec(
            tag: "walljump", loops: false,
            onStart:    [.dustAtWallKick(spread: 10)]
        ),

        // Shot poses — overlays driven by shotPoseTimer; no particle of
        // their own (the muzzle flash lives on the projectile, not Player).
        .shot:        ActionSpec(tag: "shot",         loops: false),
        .shotStrong:  ActionSpec(tag: "shot_strong",  loops: false),
        .shotRecover: ActionSpec(tag: "shot_recover", loops: false),
        .recover:     ActionSpec(tag: "recover",      loops: false),
        .shotRight:   ActionSpec(tag: "shot_right",   loops: false),
        .shotLeft:    ActionSpec(tag: "shot_left",    loops: false),
        .shotUp:      ActionSpec(tag: "shot_up",      loops: false),

        // Damage / death — Godot Damage.tscn `sparks` AnimatedSprite plays
        // once on hit; the death sequence emits the X-shaped burst from
        // PlayerDeath.gd's tickDeathSequence.
        .damage:      ActionSpec(tag: "damage",        loops: false,
                                 onStart: [.damageSpark]),
        .damageResist: ActionSpec(tag: "damage_resist", loops: false),
        // `dead` has no tag — sprite is hidden during the staged sequence.
        // The burst is fired explicitly by Player at the right tick offsets,
        // not on entry, so onStart stays empty here.
        .dead:        ActionSpec(tag: nil,             loops: false),

        // Beam-in chain — Godot Modules/Intro.gd plays beam → beam_in →
        // beam_armor in series. Each leg is a separate Action; `tickRespawn`
        // walks the timer and switches between them.
        .beam:        ActionSpec(tag: "beam",       loops: false),
        .beamIn:      ActionSpec(tag: "beam_in",    loops: false),
        .beamArmor:   ActionSpec(tag: "beam_armor", loops: false),

        // Armor capsule — armor_receive plays once on pickup, armor_blink
        // loops while the new part settles (Capsule.gd charge_state 4/5).
        .armorReceive: ActionSpec(tag: "armor_receive", loops: false),
        .armorBlink:   ActionSpec(tag: "armor_blink",   loops: false),

        .victory:     ActionSpec(tag: "victory", loops: false),

        .crouch:      ActionSpec(tag: "crouch",      loops: false),
        .crouchTalk:  ActionSpec(tag: "crouch_talk", loops: true),
        .talk:        ActionSpec(tag: "talk",        loops: true),
        .counter:     ActionSpec(tag: "counter",     loops: false),
        .punchDown:   ActionSpec(tag: "punch_down",  loops: false),
        .stairsStart: ActionSpec(tag: "stairs_start", loops: false),
        .stairs:      ActionSpec(tag: "stairs",      loops: true),
        .stairsEnd:   ActionSpec(tag: "stairs_end",  loops: false),
        .balance:     ActionSpec(tag: "balance",     loops: true),

        .rideStop:    ActionSpec(tag: "stop",        loops: false),
        .rideStopEnd: ActionSpec(tag: "stop_end",    loops: false),
    ]

    /// Lookup helper. Crashes the build only if the table goes out of sync
    /// with the enum — easier to spot than a silent fallback.
    static func spec(for action: Action) -> ActionSpec {
        guard let s = actionSpecs[action] else {
            fatalError("Player.actionSpecs is missing a row for \(action) — every Action case must have a spec.")
        }
        return s
    }
}

@MainActor
final class Player: Actor {
    private(set) var state: PlayerState = .idle
    private var dashTimer: TimeInterval = 0
    // Godot Fall.gd `if character.dashfall: set_movement_and_direction(210)`.
    // True while the actor is falling immediately after a Dash that ran out
    // of floor — preserves dash horizontal speed (210) during the descent.
    // Cleared on landing, wall-slide entry, hurt, death, and respawn.
    private var dashfall: Bool = false
    // Godot DashJump.gd extends Jump.gd with `horizontal_velocity = 210` (vs
    // the 90 default). True while the player jumped directly out of a Dash;
    // makes handleMovement preserve dash horizontal speed during the .jump
    // and the subsequent .fall (DashJump → Fall is the natural end-of-arc).
    // Cleared on landing, wall-slide entry, hurt, death, and respawn.
    private var dashJump: Bool = false
    private var shootCooldown: TimeInterval = 0
    private var shotPoseTimer: TimeInterval = 0
    private var shotPoseIsStrong: Bool = false
    private var walkStartTimer: TimeInterval = 0
    // Godot Walk.gd `minimum_time = 0.02` — Walk._EndCondition requires
    // `timer > minimum_time` before "no input" can drop the player back to
    // idle. Without it, releasing the direction key on the same frame walk
    // engaged immediately interrupts the walk and prevents the walk_start
    // animation from finishing. Reset to 0 on entering .walk; ticked while
    // .walk is the active state.
    private var walkTimer: TimeInterval = 0
    private var jumpHoldTimer: TimeInterval = 0
    private var isJumpHeld: Bool = false
    private var airDashTimer: TimeInterval = 0
    private var hasAirDashedThisJump: Bool = false
    // Godot AirDash.gd: `initial_direction` is captured at _Setup time (or
    // re-captured during the first 0.1 s if input arrives late).
    // `pressed_inverse_direction()` ends the air-dash if input flips after
    // the 0.1 s lock-in window. `has_let_go_of_input` (sticky) ends the
    // air-dash on input release. Without these, the port runs the full
    // 0.475 s regardless of input — locking the player out of mid-air control.
    private var airDashInitialSign: CGFloat = 1
    private var airDashLetGoOfInput: Bool = false
    private var wallJumpTimer: TimeInterval = 0
    // Godot Walljump.gd:40-45 → DashWallJump.gd. While the WallJump start
    // window (timer < 0.25 s) is active, a fresh dash press upgrades the
    // ability to DashWallJump: move-away speed becomes 210 px/s (vs 75) and
    // move-away duration becomes 0.134 s (vs 0.15). Sticky for the rest of
    // the wall-jump arc; cleared on landing / wall-slide entry / interrupt.
    private var dashWallJump: Bool = false
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
    // Godot Damage.gd `death_protection := 1` — the "Last Chance" survival
    // counter. Each fatal hit while above 3 HP consumes one charge instead
    // of killing; reset to 1 on respawn so every fresh life gets the save.
    private var deathProtection: Int = 1
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

    // Beam-in (Godot Modules/Intro.gd). Plays beam → beam_in → beam_armor as
    // a single chained sequence on respawn. Frame durations from x.json:
    //   beam       (frame 0)        ~0.10 s
    //   beam_in    (frames 1–6)     ~0.26 s
    //   beam_armor (frames 7–32)    ~2.16 s   → total ≈ 2.52 s
    private var beamInTimer: TimeInterval = 0
    static let beamPhaseEnd: TimeInterval = 0.10
    static let beamInPhaseEnd: TimeInterval = 0.10 + 0.26
    static let beamInDuration: TimeInterval = 0.10 + 0.26 + 2.16

    // Recover (Godot Idle/Walk play_animation("recover")) — short pose-out
    // played after a shot pose ends while grounded. Bridges the shot frame
    // back to idle/walk without a hard cut. Duration from x.json (3 frames).
    private var recoverTimer: TimeInterval = 0
    /// Captured at the moment recoverTimer is armed. Mirrors Godot
    /// Armor.gd:128 `if character_animation == "recover" and is_shooting()`:
    /// when shoot was held / charge was active as the shot pose ended, the
    /// recover frames swap to the `shot_recover` variant.
    private var recoverIsShooting: Bool = false
    static let recoverDuration: TimeInterval = 0.19

    // Talk pose — driven by an external dialog system (none yet in v1).
    // The state holds until `endTalkPose()` is called; the visual is the
    // looping `talk` portrait lip-sync (frames 49–50).

    // Armor capsule (Godot Capsule.gd) — armor_receive plays once on
    // pickup, then armor_blink loops while the new part settles. Durations
    // are from Capsule.gd's own charge_state timers (charge_state 4: 0.5s,
    // charge_state 5: 1.2s) since the animation tags are short and Godot
    // gates phase transitions on those timers, not animation completion.
    private var armorReceiveTimer: TimeInterval = 0
    private var armorBlinkTimer: TimeInterval = 0
    static let armorReceiveDuration: TimeInterval = 0.5
    static let armorBlinkDuration: TimeInterval = 1.2

    // damage_resist (Godot Damage.gd resist branch / FireDash.gd:142) —
    // played in lieu of the standard damage frames when armor reduces the
    // hit. 8 Aseprite frames at ~80 ms ≈ 0.64 s.
    private var damageResistTimer: TimeInterval = 0
    static let damageResistDuration: TimeInterval = 0.64

    // Ride Chaser stop / stop_end (Godot Accelerate.gd) — bike-mounted
    // braking pose and its release. stop holds at the last frame until
    // external bike control re-enters; stop_end auto-returns to idle.
    private var rideStopTimer: TimeInterval = 0
    private var rideStopEndTimer: TimeInterval = 0
    static let rideStopDuration: TimeInterval = 0.5
    static let rideStopEndDuration: TimeInterval = 0.4

    // Future-stage poses. Aseprite tags are present in x.json (frames
    // 55-162) but the Sigma-stage Godot scripts never trigger them; later
    // stages (Capsule rooms, NPC dialogue, Boss rematches, climbable
    // ladders, Ride Armor segments) are expected to drive them, so the
    // Swift port wires the state machine + public APIs in advance. All
    // are input-gated and either auto-return after a frame-derived
    // duration or hold until an external `endXxx()` call.
    //
    // Frame-count × 80ms (Aseprite default) gives the auto-return timers:
    //   counter      6 frames → 0.48 s
    //   punchDown    6 frames → 0.48 s
    //   stairsStart  1 frame  → 0.08 s
    //   stairsEnd    2 frames → 0.16 s
    //   aimShot*     matches shotPose for parity with the regular shoot
    private var counterTimer: TimeInterval = 0
    private var punchDownTimer: TimeInterval = 0
    private var stairsStartTimer: TimeInterval = 0
    private var stairsEndTimer: TimeInterval = 0
    private var aimShotTimer: TimeInterval = 0
    static let counterDuration: TimeInterval = 0.48
    static let punchDownDuration: TimeInterval = 0.48
    static let stairsStartDuration: TimeInterval = 0.08
    static let stairsEndDuration: TimeInterval = 0.16
    static let aimShotDuration: TimeInterval = 0.18  // matches shoot()'s shotPoseTimer ceiling

    /// Godot Actor.gd `is_low_health()`:
    ///   `current_health - 1 < max_health/4`
    /// At maxHealth=16 this means HP ≤ 4 swaps the idle pose to `weak`.
    var isLowHealth: Bool {
        currentHealth - 1 < maxHealth / 4
    }

    // Charge halo child node, swapped when charge level changes. Mirrors
    // Godot Charge.gd ChargingParticle / ChargedParticle visibility toggles.
    private var chargeHaloNode: SKNode?
    private var chargeHaloLevel: Int = -1
    // Atlases for the charge overlay (Godot charge_1.png / charge_2.png).
    // Indexed by charge level; nil entries fall back to the colored halo.
    private var chargeAtlases: [Int: SpriteAtlas] = [:]

    // Per-(action,VFX-index) cadence timers for the spec-driven continuous
    // emitters declared in `Player.actionSpecs`. Keyed by
    // "<action.rawValue>#<index>" — see `tickContinuousVFX(for:dt:)`.
    // Replaces the previous hand-rolled `dashGhostTimer` /
    // `dashSmokeTimer` / `wallSlideSmokeTimer` triplet.
    private var continuousVFXTimers: [String: TimeInterval] = [:]

    // Preview-mode hooks. When `previewMode == true`, `tick(...)` short-circuits
    // input + physics and runs ONLY the animation/VFX paths against
    // `previewAction`. Used by `PlayerPreviewScene` so the standalone
    // /assets/player-preview.html page can render real Swift-driven Player
    // animations + particles without the boss arena.
    var previewMode: Bool = false
    private(set) var previewAction: Action?

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

    // Scene-callback seam — see Actors/PlayerWorld.swift. Held weakly so a
    // scene swap doesn't pin the previous BossBattleScene through Player.
    weak var world: (any PlayerWorld)?

    private let visual: SKSpriteNode
    private var atlas: SpriteAtlas?
    private var currentAnimationTag: String?

    var previewFrameIndex: Int? {
        guard let atlas,
              let currentAnimationTag,
              let animation = atlas.animation(currentAnimationTag),
              let texture = visual.texture,
              let localIndex = animation.textures.firstIndex(where: { $0 === texture }) else {
            return nil
        }
        return animation.firstFrameIndex + localIndex
    }

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
        // Mirror Godot AnimatedSprite2D: each frame is drawn at its native
        // pixel size. SKAction.animate defaults to resize:false, which would
        // stretch every frame to the SKSpriteNode's initial (64x56) size and
        // distort sprites whose source rect is smaller (e.g. idle 30x34).
        let first = anim.textures[0]
        visual.texture = first
        visual.size = first.size()
        if anim.textures.count == 1 { return }
        let action = SKAction.animate(
            with: anim.textures,
            timePerFrame: anim.timePerFrame,
            resize: true,
            restore: false
        )
        let runner = repeating ? SKAction.repeatForever(action) : action
        visual.run(runner, withKey: "anim")
    }

    // MARK: - Tick

    func tick(_ dt: TimeInterval, input: InputManager, stageWidth: CGFloat, floorY: CGFloat) {
        if previewMode {
            tickPreview(dt)
            return
        }
        advance(dt)

        // Cooldowns
        shootCooldown = max(0, shootCooldown - dt)

        // Mirrors Godot `character.deactivate()` in PlayerDeath._Setup:
        // `listening_to_inputs = false` gates Charge._Update / Shot._Update,
        // so dead/victory frames stop accepting input. Physics still settle
        // (disable_floor_snap + position pinning in Godot) — here we just
        // integrate the frozen body so clampToStage keeps it in bounds.
        // States that gate input: physics still settle but no controller
        // input drives transitions. Each state owns its own tick function.
        if isInputGatedState(state) {
            prevShootHeld = false
            switch state {
            case .dead:         tickDeathSequence(dt)
            case .beamIn:       tickBeamIn(dt)
            case .armorReceive: tickArmorReceive(dt)
            case .armorBlink:   tickArmorBlink(dt)
            case .damageResist: tickDamageResist(dt)
            case .rideStop:     tickRideStop(dt)
            case .rideStopEnd:  tickRideStopEnd(dt)
            case .counter:      tickCounter(dt)
            case .punchDown:    tickPunchDown(dt)
            case .stairsStart:  tickStairsStart(dt)
            case .stairsEnd:    tickStairsEnd(dt)
            case .aimShotRight, .aimShotLeft, .aimShotUp:
                tickAimShot(dt)
            case .talk, .victory,
                 .crouch, .crouchTalk, .balance, .stairs:
                break  // Held until external code releases the pose.
            default:
                break
            }
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
            let prevLevel = chargeLevel
            chargeTimer += dt
            if chargeTimer > WeaponConstants.chargeFullThreshold { chargeLevel = 2 }
            else if chargeTimer > WeaponConstants.chargeMidThreshold { chargeLevel = 1 }
            else { chargeLevel = 0 }
            if chargeLevel == 2 && prevLevel < 2 {
                AudioManager.shared.playSFX(AudioAssets.chargeMax)
            }
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
            // wall-collision with matching just-pressed input direction.
            // Invulnerability outlasts the hurt state by ~1.15s (1.75 - 0.6),
            // handled by the Actor invulnerability timer independently of state.
            hurtTimer -= dt
            velocity.dx = hurtKnockbackSign * PhysicsConstants.hurtKnockbackX
            // Godot Damage._EndCondition:
            //   `if collide_with_wall AND just_pressed_axis == wall_direction:
            //       return true`
            // — pressing INTO a wall the player has been knocked against
            // recovers early (player canceled the recoil intentionally).
            let recoverIntoWall: Bool
            if let wc = wallContact {
                recoverIntoWall = (wc == .left && input.leftPressed)
                               || (wc == .right && input.rightPressed)
            } else {
                recoverIntoWall = false
            }
            if hurtTimer <= 0 || recoverIntoWall {
                state = onFloor ? .idle : .fall
            }
        case .dead, .victory, .beamIn,
             .talk, .armorReceive, .armorBlink, .damageResist,
             .rideStop, .rideStopEnd,
             .crouch, .crouchTalk, .balance, .counter, .punchDown,
             .stairsStart, .stairs, .stairsEnd,
             .aimShotRight, .aimShotLeft, .aimShotUp:
            // Unreachable — input-gated early return above short-circuits these.
            break
        }

        // Edge-triggered shoot (uncharged tap) — fire immediately if not charging.
        if input.shootPressed && shootCooldown <= 0 && state != .dash && state != .airDash && chargeLevel == 0 {
            shoot()
        }

        // Tick shot pose overlay timer. When the shot pose ends while grounded
        // (and not in a non-idle/walk state), kick off the recover animation —
        // Godot's Idle/Walk play "recover" as a pose-out before falling back
        // to the looping idle/walk frames.
        let prevShotPoseTimer = shotPoseTimer
        if shotPoseTimer > 0 { shotPoseTimer = max(0, shotPoseTimer - dt) }
        if walkStartTimer > 0 { walkStartTimer = max(0, walkStartTimer - dt) }
        if recoverTimer > 0 { recoverTimer = max(0, recoverTimer - dt) }
        // Godot Walk.gd `timer > minimum_time` gate — accumulate while .walk
        // is the active state. Reset on entry (enterWalk / walkStart→walk).
        if state == .walk { walkTimer += dt }
        if prevShotPoseTimer > 0 && shotPoseTimer == 0 && onFloor &&
           (state == .idle || state == .walk || state == .walkStart) {
            recoverTimer = Player.recoverDuration
            // Capture the shooting state at recover-arm time so the visual
            // chooses `shot_recover` (Godot Armor.gd:128) when the trigger
            // is still held / charging on the same frame.
            recoverIsShooting = input.shoot || chargeLevel > 0
        }

        applyGravity(dt)
        integrate(dt)
        clampToStage(width: stageWidth, floorY: floorY)
        tickFloorTimer(dt)
        updateWallContact(stageWidth: stageWidth)

        // Reset air-dash one-shot when grounded again.
        if onFloor { hasAirDashedThisJump = false }
        // Godot Fall.gd `_Interrupt` clears dashfall; the only successful
        // termination of a dashfall is touching ground or interrupting the
        // ability (wall-slide / hurt / death). Clear here when landed.
        // DashJump's 210-preservation also resolves on landing.
        // DashWallJump.on_touch_floor restores normal walk speed via the
        // standard onFloor transition below; clear the flag so the next
        // wall-jump starts fresh as a regular WallJump unless dash is repressed.
        if onFloor {
            dashfall = false
            dashJump = false
            dashWallJump = false
        }

        // Resolve state after physics
        if onFloor {
            if state == .jump || state == .fall || state == .airDash {
                let next = abs(velocity.dx) > 1 ? enterWalk() : .idle
                if next == .walk { walkTimer = 0 }
                state = next
            } else if state == .idle && abs(velocity.dx) > 1 {
                let next = enterWalk()
                if next == .walk { walkTimer = 0 }
                state = next
            } else if state == .walkStart && walkStartTimer <= 0 {
                if abs(velocity.dx) > 1 {
                    walkTimer = 0
                    state = .walk
                } else {
                    state = .idle
                }
            } else if state == .walk && abs(velocity.dx) < 1
                      && walkTimer > 0.02 {
                // Godot Walk._EndCondition: only end walk after the
                // minimum_time grace AND when no direction is pressed.
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
        // Godot Fall.gd `if character.dashfall: set_movement_and_direction(210)` —
        // during a dashfall the horizontal speed is the dash speed (210),
        // not the walk speed (90). Direction follows held input but the
        // magnitude stays at 210 until the player lands or hits a wall.
        // No input → keep drifting in `facing` direction at 210.
        // DashJump.tscn extends the same 210-px/s preservation across .jump
        // (and the subsequent .fall once the ascent peaks) — same rule.
        let dashfallActive = state == .fall && dashfall
        let dashJumpActive = (state == .jump || state == .fall) && dashJump
        let preserveDashSpeed = dashfallActive || dashJumpActive
        // Godot Walk._StartCondition / _EndCondition:
        //   `if is_colliding_with_wall_except_feet() == get_pressed_direction(): return`
        // — pressing INTO a wall while grounded must NOT engage walk; without
        // this, the actor reads as walking against an immovable wall and the
        // ramp/animation continues to fire. Only zero out the horizontal
        // input here (still face the wall); preserve dash-jump / dashfall
        // momentum since those owe their speed to a different ability.
        let pressingIntoWall = (wallContact == .left && input.left)
                            || (wallContact == .right && input.right)
        if horizontal != 0 {
            let desired: Facing = horizontal > 0 ? .right : .left
            if desired != facing {
                face(desired)
            }
            if preserveDashSpeed {
                velocity.dx = horizontal * PhysicsConstants.playerDashSpeed
            } else if pressingIntoWall && onFloor {
                // Walk gated by wall contact — face the wall but stay still.
                velocity.dx = 0
            } else {
                // Godot Walk._Update: when starting_from_stop (last ability ==
                // Idle) the first 0.08 s applies horizontal_velocity / 4
                // (22.5 px/s) to ramp the player out of a standing start;
                // afterwards full horizontal_velocity. Swift's `state ==
                // .walkStart` is the analogue of starting_from_stop, and
                // `walkStartTimer` decreases from 0.09 → 0 (~one walk_start
                // frame) — using the remaining window to gate the ramp keeps
                // us within ~10 % of Godot timing without a parallel timer.
                let rampActive = state == .walkStart && walkStartTimer > 0.01
                let speed = rampActive
                    ? PhysicsConstants.playerWalkSpeed / 4
                    : PhysicsConstants.playerWalkSpeed
                velocity.dx = horizontal * speed
            }
        } else if preserveDashSpeed {
            velocity.dx = facing.sign * PhysicsConstants.playerDashSpeed
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
        // Godot Jump._StartCondition: `has_just_been_on_floor(leeway_time)`
        // with leeway_time = 0.1 s. This is the coyote window — pressing jump
        // up to 0.1 s after walking off a ledge still triggers a ground jump.
        if input.jumpPressed && hasJustBeenOnFloor(leeway: 0.1) && state != .jump {
            velocity.dy = PhysicsConstants.playerJumpVelocity
            onFloor = false
            state = .jump
            jumpHoldTimer = 0
            isJumpHeld = true
            AudioManager.shared.playSFX(AudioAssets.jump)
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
        applyOnStartVFX(for: .dash)
        AudioManager.shared.playSFX(AudioAssets.dash)
    }

    private func handleDash(_ dt: TimeInterval, input: InputManager) {
        dashTimer -= dt
        velocity.dx = facing.sign * PhysicsConstants.playerDashSpeed
        tickContinuousVFX(for: .dash, dt: dt)
        // Mid-dash jump cancel — Godot DashJump.gd, fires when input.jump
        // arrives within `dash_leeway_time = dash.dash_duration` while Dash is
        // executing. DashJump.tscn `horizontal_velocity = 210` (vs Jump.tscn's
        // 90), so the jump preserves the dash speed for the whole arc.
        if input.jumpPressed && onFloor {
            velocity.dy = PhysicsConstants.playerJumpVelocity
            velocity.dx = facing.sign * PhysicsConstants.playerDashSpeed
            dashJump = true
            state = .jump
            onFloor = false
            jumpHoldTimer = 0
            isJumpHeld = true
            AudioManager.shared.playSFX(AudioAssets.jump)
            return
        }
        // Leaving the floor mid-dash converts to a fall and preserves horizontal
        // momentum (Godot Dash: _EndCondition returns false off-floor, then Fall
        // reads character.dashfall to keep 210 px/s instead of 90).
        if !onFloor {
            dashfall = true
            state = .fall
            return
        }
        let pressingOpposite = (facing == .right && input.left && !input.right)
                            || (facing == .left && input.right && !input.left)
        // Godot Dash._EndCondition: `if facing_a_wall(): return true` — running
        // into a wall ends the dash, even if the dash key is still held.
        let facingIntoWall = (wallContact == .left && facing == .left)
                          || (wallContact == .right && facing == .right)
        if !input.dash || pressingOpposite || dashTimer <= 0 || facingIntoWall {
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
        // Godot AirDash._Setup: `initial_direction = character.get_facing_direction()`.
        // Re-captured during the first 0.1 s if input arrives late
        // (handleAirDash below). `has_let_go_of_input` is sticky across the
        // ability's lifetime; reset on each fresh _Setup.
        airDashInitialSign = direction.sign
        airDashLetGoOfInput = false
        applyOnStartVFX(for: .airDash)
        AudioManager.shared.playSFX(AudioAssets.dash)
    }

    private func handleAirDash(_ dt: TimeInterval, input: InputManager) {
        airDashTimer -= dt
        velocity.dx = facing.sign * PhysicsConstants.playerDashSpeed
        tickContinuousVFX(for: .airDash, dt: dt)

        // Godot AirDash.gd `pressed_inverse_direction()`:
        //   if timer > 0.1: input != 0 AND input != initial_direction → end
        //   else:           initial_direction = input  (re-capture window)
        // Combined with `check_for_let_go_of_input()`: input == 0 OR
        // pressed_inverse_direction() → has_let_go_of_input := true (sticky).
        let inputDir: CGFloat = (input.right ? 1 : 0) - (input.left ? 1 : 0)
        let timeSinceStart = PhysicsConstants.playerAirDashDuration - airDashTimer
        let pressedInverse: Bool
        if timeSinceStart > 0.1 {
            pressedInverse = inputDir != 0 && inputDir != airDashInitialSign
        } else {
            if inputDir != 0 { airDashInitialSign = inputDir }
            pressedInverse = false
        }
        if inputDir == 0 || pressedInverse {
            airDashLetGoOfInput = true
        }

        // Pressing-into-wall ends AirDash early (Godot AirDash._EndCondition:
        // `if pressing_towards_wall() or character.is_on_floor(): return true`).
        let pressingIntoWall = (wallContact == .left && input.left)
                            || (wallContact == .right && input.right)
        if airDashTimer <= 0 || pressingIntoWall || onFloor || airDashLetGoOfInput {
            gravityScale = 1
            if onFloor {
                velocity.dx = 0
                state = .idle
            } else {
                // Godot AirDash.change_animation_if_falling: `EndAbility();
                // character.start_dashfall()`. Preserve the 210 px/s carry into
                // Fall — without dashfall the player would suddenly drop to
                // walk-speed mid-air on AirDash exit.
                dashfall = true
                state = .fall
            }
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
            // Godot Wallslide._Interrupt: `if vertical_speed > 0:
            // set_vertical_speed(40)`. Y-down "vertical_speed > 0" = falling;
            // clamp magnitude to 40 px/s. Y-up port → if vy < 0 (descending
            // faster than 40), raise it to -40 so the slide-to-fall handoff
            // doesn't blast the player downward at the slideSpeed (90).
            if !onFloor && velocity.dy < -40 {
                velocity.dy = -40
            }
            state = onFloor ? .idle : .fall
            return
        }
        // Godot Wallslide.gd:_Setup `set_direction(- get_pressed_direction())`
        // — slide animation faces AWAY from the wall, so X visually presses his
        // back/side against the wall.
        face(wallContact.opposite)
        // Godot Wallslide.gd:_Update `set_horizontal_speed(horizontal_speed *
        // wallgrab_direction)` with `horizontal_speed = 90` (hardcoded var,
        // NOT the @export `horizontal_velocity` which Player.tscn overrides
        // to 0). Pushes the body INTO the wall every frame so the contact
        // doesn't slip even if the floor surface tilts or the wall is curved.
        velocity.dx = wallContact.sign * WallSlideConstants.slideSpeed
        wallSlideTimer += dt
        if wallSlideTimer > WallSlideConstants.startDelay {
            velocity.dy = -WallSlideConstants.slideSpeed
            // Godot Wallslide.gd `_Update` emits the WallSlide Particles every
            // frame after start_delay. The cadence is declared in
            // `Player.actionSpecs[.slide].continuous` and the dispatcher
            // resolves the wall-contact anchor live.
            tickContinuousVFX(for: .slide, dt: dt)
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
        // the flip. The dust spawn happens via the spec dispatcher AFTER the
        // state transition, but BEFORE wallContact is cleared on launch — so
        // `dustAtWallContact` resolves to the right pixel.
        let wallSide = wallContact ?? facing
        state = .wallJump
        dashWallJump = false
        applyOnStartVFX(for: .wallJump)
        // Godot Walljump.gd:_Setup zeroes both velocity components. Motion is
        // gated behind `start_delay = 0.116 s` (Player.tscn override). During
        // that window process_gravity / ascent_with_slowdown_after_delay /
        // set_movement_and_direction ALL skip — vy and vx stay at 0 and the
        // body is glued to the wall.
        let walljumpDir: CGFloat = -wallSide.sign
        // Godot Walljump.gd:_Setup `set_direction(- walljump_direction)` — kick
        // pose faces TOWARD the wall while the body launches away. Visually X
        // arches outward with his front to the wall.
        face(wallSide)
        velocity.dx = 0
        velocity.dy = 0
        // WallJump replaces any prior Jump/Fall preservation; the kick-off
        // physics override the 210-px/s carry from a DashJump or dashfall.
        dashJump = false
        dashfall = false
        onFloor = false
        // Godot Walljump.gd skips `process_gravity` until `delay_has_expired()`.
        // Toggle gravityScale to 0 for the start_delay window so the manual
        // applyGravity in tick() doesn't undo our zeroed vy. Restored to 1 in
        // handleWallJump as soon as start_delay expires.
        gravityScale = 0
        // Godot Walljump.gd:_Setup position offset:
        //   position.x += 2 * walljump_direction  (push away from wall)
        //   position.y -= 2                       (lift up; Y-up port subtracts
        //                                          from position via +2)
        position.x += 2 * walljumpDir
        position.y += 2
        wallJumpTimer = 0
        wallContact = nil
        AudioManager.shared.playSFX(AudioAssets.jump)
    }

    private func handleWallJump(_ dt: TimeInterval, input: InputManager) {
        wallJumpTimer += dt
        let startDelay = WallJumpConstants.startDelay
        // Godot Walljump.gd:40-45 `execute_dashwalljump_on_input`: while the
        // wall-jump is still in its first 0.25 s, a dash-press upgrades to
        // DashWallJump — Player.tscn `DashWallJump.horizontal_velocity = 210`
        // and `move_away_duration = 0.134` (vs WallJump's 75 / 0.15). Sticky
        // for the rest of the arc; cleared on land / wall-slide / interrupt.
        if !dashWallJump && wallJumpTimer < 0.25 && input.dashPressed {
            dashWallJump = true
        }
        let moveAwayDuration: TimeInterval = dashWallJump
            ? 0.134
            : WallJumpConstants.moveAwayDuration
        let moveAwaySpeed: CGFloat = dashWallJump
            ? PhysicsConstants.playerDashSpeed
            : WallJumpConstants.moveAwaySpeed
        let moveAwayEnd = startDelay + moveAwayDuration
        // facing was set to point TOWARD the wall in startWallJump (kick pose),
        // so the launch direction is the negation of facing.sign.
        let awaySign: CGFloat = -facing.sign

        if wallJumpTimer < startDelay {
            // Phase A — start_delay lock. vy=0, vx=0, no gravity, no ascent.
            // Godot Walljump.gd: process_gravity / ascent / set_movement all
            // skip until `delay_has_expired()` returns true.
            velocity.dx = 0
            velocity.dy = 0
            return
        }
        // Phase A just ended — restore gravity so applyGravity in tick() runs
        // naturally on top of the explicit ascent velocity.
        if gravityScale == 0 {
            gravityScale = 1
        }
        if wallJumpTimer < moveAwayEnd {
            // Phase B — drift away from wall at move_away_speed while
            // Jump.gd's slowdown ascent runs. Ascent timer is measured from
            // the start of phase B (delay-corrected), matching Godot's
            // `super.ascent_with_slowdown_after_delay` which fires only after
            // delay expiry.
            velocity.dx = awaySign * moveAwaySpeed
            applyJumpAscent(dt, jumpHoldTimerOverride: wallJumpTimer - startDelay)
        } else {
            // Phase C — full Jump.gd behaviour. Walking input from this
            // point governs horizontal motion just like a regular jump.
            // For DashWallJump, the inertia continues at 210 until input
            // overrides — Godot's super.set_movement_and_direction reads
            // horizontal_velocity (210 for DashWallJump) when no input.
            let horizontal: CGFloat = (input.right ? 1 : 0) - (input.left ? 1 : 0)
            let driftSpeed: CGFloat = dashWallJump
                ? PhysicsConstants.playerDashSpeed
                : WallJumpConstants.moveAwaySpeed
            velocity.dx = horizontal != 0
                ? horizontal * PhysicsConstants.playerWalkSpeed
                : awaySign * driftSpeed
            applyJumpAscent(dt, jumpHoldTimerOverride: wallJumpTimer - startDelay)
        }

        // Godot Walljump._EndCondition lines 67-72:
        //   if timer > 0.05 + start_delay:
        //     if facing_a_wall() and character.get_vertical_speed() > 0:
        //       return true
        //   return super._EndCondition()    # Jump: is_on_floor and changed_animation
        // Y-up port: `vertical_speed > 0` (falling, in Y-down) → `velocity.dy < 0`.
        // facing_a_wall: did we re-acquire wall contact on the same side we
        // were kicking off from? wallContact was cleared at launch; reading it
        // back from the live update (set in the next tick) catches it.
        if wallJumpTimer > 0.05 + startDelay {
            if let contact = wallContact, contact.sign == facing.sign,
               velocity.dy < 0 {
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
        } else if let wallHit = world?.sigmaWallContact(for: hitbox) {
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
        // WallSlide interrupts a dashfall / dashJump; Godot Fall._Interrupt
        // and Jump._Interrupt both clear their preservation flags here.
        // DashWallJump's WallSlide.conflicting_moves likewise stops the
        // long-distance carry.
        dashfall = false
        dashJump = false
        dashWallJump = false
        state = .slide
        // Match Godot Wallslide.gd: facing AWAY from the wall during slide so
        // the sprite presses its back/side against the surface. Set on entry
        // to avoid a 1-frame flicker before handleSlide repeats it.
        face(wallContact.opposite)
        // Continuous WallSlide Particles will start firing on the first tick
        // after start_delay (handleSlide). Reset their cadence timer here so
        // the first puff lands at start_delay+0, not start_delay+0.12.
        applyOnStartVFX(for: .slide)
    }

    // MARK: - Shoot

    private func shoot() {
        guard let world else { return }
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
        world.spawnPlayerShot(chargeLevel: chargeLevel, from: muzzle, facing: facing)
        // Brief upper-body shot pose overlay. Uses shot_strong atlas tag for charge 2+.
        // Godot Shot.gd `default_arm_point_duration = 0.3` and
        // `_EndCondition` requires `timer > 0.3` before the pose can end —
        // applies uniformly to lemon and charged shots in the reference.
        shotPoseIsStrong = chargeLevel >= 2
        shotPoseTimer = 0.3
        AudioManager.shared.playSFX(shotPoseIsStrong ? AudioAssets.chargedShot : AudioAssets.shot)
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

    // MARK: - VFX Dispatcher
    // Routes Player.VFX cases to the right PlayerEffects factory at the live
    // scene anchor (feet / wall-contact / body-center). All particle spawns
    // flow through this — the imperative state-machine handlers call
    // `applyOnStartVFX(_:)` / `tickContinuousVFX(_:dt:)` with a `Player.Action`
    // enum, never the low-level `PlayerEffects.*` factories directly.

    private func continuousVFXKey(_ action: Action, _ index: Int) -> String {
        "\(action.rawValue)#\(index)"
    }

    /// Fire each `onStart` VFX of the spec once, and zero the cadence
    /// timers for any continuous emitters so the first emission lands on
    /// the next tick (matches Godot ability `_Setup` semantics).
    private func applyOnStartVFX(for action: Action) {
        let spec = Player.spec(for: action)
        for vfx in spec.onStart {
            spawnVFX(vfx)
        }
        for i in spec.continuous.indices {
            continuousVFXTimers[continuousVFXKey(action, i)] = 0
        }
    }

    /// Drain cadence timers for the action's continuous emitters and
    /// re-spawn whichever ones expired this tick. Call once per frame
    /// from the action's per-frame handler (`handleDash`, `handleSlide`, …).
    private func tickContinuousVFX(for action: Action, dt: TimeInterval) {
        let spec = Player.spec(for: action)
        for (i, entry) in spec.continuous.enumerated() {
            let key = continuousVFXKey(action, i)
            var t = continuousVFXTimers[key] ?? 0
            t -= dt
            if t <= 0 {
                spawnVFX(entry.0)
                t = entry.1
            }
            continuousVFXTimers[key] = t
        }
    }

    /// Translate a single VFX spec into an SKNode under the battle scene at
    /// the right anchor relative to the live Player position / facing /
    /// wall-contact. Anchors are intentionally resolved here (not in the
    /// table) so they always reflect the current frame's state.
    private func spawnVFX(_ spec: VFX) {
        // Parent VFX onto whatever scene currently hosts the Player rather
        // than the battle world specifically — `PlayerPreviewScene` (used
        // by /assets/player-preview.html) doesn't adopt PlayerWorld and
        // would otherwise drop every particle silently.
        guard let host = self.parent else { return }
        let node: SKNode?
        switch spec {
        case .dustBehindFeet(let spread):
            // Godot `Dash Smoke Particles` (Player.tscn:328) sits at
            // (-10, 17.99) on `animatedSprite`, which itself is at (0, -4)
            // relative to the body root — i.e. (-10, +14) in root coords,
            // 1 px above the feet of the 30-tall x_collision_box. The
            // animatedSprite is mirrored on facing flip, so the local-x
            // sign tracks `-facing.sign` for the player to push the puff
            // BEHIND the dash direction. Y-up port: feet = position.y →
            // dust at position.y + 1.
            node = PlayerEffects.dustPuff(
                at: CGPoint(x: position.x - facing.sign * 10,
                            y: position.y + 1),
                color: SKColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 0.95),
                spread: spread
            )
        case .dustAtWallContact(let spread):
            // Godot `WallSlide Particles` (Player.tscn:342) sits at
            // (-14, 10.99) on `animatedSprite` → root coords (-14, +7) →
            // 8 px above feet, 14 px out toward the wall (animatedSprite
            // mirrors with facing). Slide pose faces AWAY from the wall,
            // so the wall side equals -facing.sign, equivalently
            // wallContact.sign. Earlier port emitted at body-edge (±7) and
            // body-mid Y (+12) which placed the puff at hip level instead
            // of low-shin — visually wrong against the Godot reference.
            let wallSign = (wallContact ?? facing).sign
            node = PlayerEffects.dustPuff(
                at: CGPoint(x: position.x + wallSign * 14,
                            y: position.y + 8),
                color: SKColor(red: 0.82, green: 0.82, blue: 0.85, alpha: 0.9),
                spread: spread
            )
        case .dustAtWallKick(let spread):
            // Godot `WallJump Particle` (Player.tscn:356) sits at
            // (+14, 17) on `animatedSprite` → root coords (+14, +13) →
            // 2 px above feet (vs. WallSlide's +8 — kick puff is at the
            // foot push-off, slide puff at the hip rub). Walljump.gd:
            // _Setup faces the player TOWARD the wall during the kick
            // (set_direction(-walljump_direction)), so the mirrored
            // animatedSprite places the puff on the wall side regardless
            // of which wall — wallContact.sign covers it directly.
            let wallSign = (wallContact ?? facing).sign
            node = PlayerEffects.dustPuff(
                at: CGPoint(x: position.x + wallSign * 14,
                            y: position.y + 2),
                color: SKColor(red: 0.82, green: 0.82, blue: 0.85, alpha: 0.9),
                spread: spread
            )
        case .dashStreak:
            // Godot `Dash/dash_particle` Sprite2D (Player.tscn:1023) at
            // (-22, 0) on the Dash node — root coords (-22, 0), i.e. 15 px
            // above feet (root center). SpriteEffect.gd mirrors the streak
            // via `_particle.scale.x = scale_x` (pressed_direction), so
            // x = -facing.sign * 22 puts the streak BEHIND the dash.
            node = PlayerEffects.dashStreak(
                kind: .dash,
                at: CGPoint(x: position.x - facing.sign * 22,
                            y: position.y + 15),
                mirrored: facing.sign < 0
            )
        case .airDashStreak:
            // Godot `AirDash/dash_particle` Sprite2D (Player.tscn:886) at
            // (-16, +4) on the AirDash node — root coords (-16, +4), i.e.
            // 11 px above feet. AirDash.gd overrides `emit_particles` to a
            // no-op, so this streak is the ONLY VFX of an air dash.
            node = PlayerEffects.dashStreak(
                kind: .airdash,
                at: CGPoint(x: position.x - facing.sign * 16,
                            y: position.y + 11),
                mirrored: facing.sign < 0
            )
        case .damageSpark:
            // Godot `Damage/sparks` AnimatedSprite (Player.tscn:609) sits
            // at (0, -8) on the Damage node, which is parented to the
            // root at (0, 0) — i.e. 8 px above root center, 23 px above
            // feet (root center = feet + 15). Earlier port spawned at
            // body-mid (+15) which placed the spark at the navel rather
            // than at the upper chest where the hit registers visually.
            node = PlayerEffects.damageSpark(
                at: CGPoint(x: position.x,
                            y: position.y + Player.bodySize.height / 2 + 8)
            )
        case .deathBurst:
            node = PlayerEffects.deathExplosion(
                at: CGPoint(x: position.x,
                            y: position.y + Player.bodySize.height / 2)
            )
        }
        if let node { host.addChild(node) }
    }

    // MARK: - Preview mode
    // Single-Player viewer used by `PlayerPreviewScene` to back the standalone
    // /assets/player-preview.html page. Drives animation tag + VFX dispatcher
    // ONLY — no input read, no gravity, no boss/wall collision. Lets the user
    // visually verify each `Player.Action` row of `actionSpecs` (tag + loop +
    // particles) without booting the boss arena.

    /// Switch the Player to preview mode and play `action`. The animation
    /// tag and `onStart` VFX fire once; `tickContinuousVFX` keeps emitting
    /// the spec's continuous entries until another preview call replaces
    /// `previewAction`. Calling with the same action restarts both.
    func preview(_ action: Action) {
        previewMode = true
        previewAction = action
        velocity = .zero
        gravityScale = 0
        onFloor = true
        // Pin the FSM to a non-input-gated leaf so any stray code path that
        // peeks at `state` (HUD, harness) sees a sane value. Visual is driven
        // entirely by `playAnimation` below — `state` doesn't reach
        // `updateVisual()` because preview-mode never calls it.
        state = .idle
        visual.isHidden = false
        // Wall-relative VFX (`dustAtWallContact`, `dustAtWallKick`) read
        // `wallContact ?? facing` to decide which side the dust spawns on.
        // In real gameplay `wallContact` is always populated, so the fallback
        // doesn't matter — but the preview never enters wall handling, so we
        // synthesise it here per-action semantic to keep sprite + particle
        // on the same wall side:
        //   .slide    — Wallslide.gd:14 faces the player AWAY from the wall,
        //               so wall = facing.opposite.
        //   .wallJump — Walljump.gd:25 faces the player TOWARD the wall,
        //               so wall = facing.
        switch action {
        case .slide:    wallContact = facing.opposite
        case .wallJump: wallContact = facing
        default:        wallContact = nil
        }
        applyOnStartVFX(for: action)
        let spec = Player.spec(for: action)
        if let tag = spec.tag {
            // Force re-trigger even when the same action is selected twice —
            // `playAnimation` early-returns on `currentAnimationTag != tag`.
            currentAnimationTag = nil
            playAnimation(tag, repeating: spec.loops)
        } else {
            // .dead has no tag; hide the sprite the same way the death
            // sequence does, so the burst (if any) reads cleanly.
            visual.isHidden = true
        }
    }

    /// Per-frame tick when `previewMode` is true. Runs the Actor base
    /// (invuln blink + flash timer cleanup) and the continuous-VFX cadence
    /// for the active preview action. Animation playback is owned by SKAction.
    private func tickPreview(_ dt: TimeInterval) {
        advance(dt)
        if let action = previewAction {
            tickContinuousVFX(for: action, dt: dt)
        }
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

    /// Death burst is a timer-staged effect (PlayerDeath.gd fires it twice
    /// during the 0.5s + 0.5s window), so it doesn't fit `applyOnStartVFX`'s
    /// "once on action entry" semantics. Route it through the same VFX
    /// dispatcher and tack the SFX on as a side-effect.
    private func spawnDeathExplosion() {
        spawnVFX(.deathBurst)
        AudioManager.shared.playSFX(AudioAssets.explosion)
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
        // Death is a hard interrupt — Godot PlayerDeath terminates Fall and
        // Jump; preservation flags must not survive into the next life.
        dashfall = false
        dashJump = false
        AudioManager.shared.playSFX(AudioAssets.death)
        // Drop any active charge halo so the explosion isn't visually polluted.
        chargeHaloNode?.removeFromParent()
        chargeHaloNode = nil
        chargeHaloLevel = -1
        deathTimer = 0
        deathSequenceBegun = false
        deathSecondBurstFired = false
        // Godot PlayerDeath._Setup line 31: `character.remove_invulnerability_shader()`.
        // Stops the alpha blink so the dying sprite does not look "still
        // invincible" during the 0.5 s death-pause before the explosion.
        // The i-frame timer keeps running underneath — only the visual is
        // detached. respawn() restores the shader for the next life.
        removeInvulnerabilityShader()
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

    /// Advances the Godot Modules/Intro.gd beam-in sequence. The state ends
    /// after the beam → beam_in → beam_armor chain finishes (~2.52 s) and
    /// drops back to idle so normal input begins driving Player.
    private func tickBeamIn(_ dt: TimeInterval) {
        beamInTimer += dt
        if beamInTimer >= Player.beamInDuration {
            beamInTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    /// Tick hook for the BossBattleScene `.intro` phase. The fight tick
    /// (`tick(_:input:stageWidth:floorY:)`) is gated off during intro to
    /// keep input frozen — but the beam-in animation still needs to advance
    /// so the player visibly materialises on the floor while Sigma descends.
    func tickIntro(_ dt: TimeInterval) {
        guard state == .beamIn else { return }
        tickBeamIn(dt)
        updateVisual()
    }

    // MARK: - Input-gated states (Godot Capsule.gd / Damage.gd / Accelerate.gd)

    /// True for states that pause input handling until external code (or an
    /// internal timer) releases them. Mirrors Godot's pattern of one-shot
    /// abilities that own the player until their own end-condition fires.
    private func isInputGatedState(_ s: PlayerState) -> Bool {
        switch s {
        case .dead, .victory, .beamIn,
             .talk, .armorReceive, .armorBlink, .damageResist,
             .rideStop, .rideStopEnd,
             .crouch, .crouchTalk, .balance, .counter, .punchDown,
             .stairsStart, .stairs, .stairsEnd,
             .aimShotRight, .aimShotLeft, .aimShotUp:
            return true
        default:
            return false
        }
    }

    private func tickArmorReceive(_ dt: TimeInterval) {
        armorReceiveTimer += dt
        if armorReceiveTimer >= Player.armorReceiveDuration {
            armorReceiveTimer = 0
            // Godot Capsule.gd: charge_state 4 → 5 plays armor_blink next.
            state = .armorBlink
            armorBlinkTimer = 0
        }
    }

    private func tickArmorBlink(_ dt: TimeInterval) {
        armorBlinkTimer += dt
        if armorBlinkTimer >= Player.armorBlinkDuration {
            armorBlinkTimer = 0
            // Godot Capsule.gd: charge_state 5 → 6 plays victory; we drop
            // to idle here so the capsule (or test harness) decides what
            // comes next instead of forcing victory.
            state = onFloor ? .idle : .fall
        }
    }

    private func tickDamageResist(_ dt: TimeInterval) {
        damageResistTimer += dt
        if damageResistTimer >= Player.damageResistDuration {
            damageResistTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    private func tickRideStop(_ dt: TimeInterval) {
        rideStopTimer += dt
        // Godot Accelerate.gd holds the bike at the last `stop` frame
        // until the rider re-applies throttle; nothing auto-advances here.
        // The state is released by playRideStopEnd() or external bike code.
        _ = rideStopTimer
    }

    private func tickRideStopEnd(_ dt: TimeInterval) {
        rideStopEndTimer += dt
        if rideStopEndTimer >= Player.rideStopEndDuration {
            rideStopEndTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    /// Enter the dialogue lip-sync pose. Mirrors Godot AnimatedText.gd:163
    /// which assigns `portrait.animation = "talk"` while a dialogue line is
    /// streaming. Loops until `endTalkPose()` is called.
    func playTalkPose() {
        guard state != .dead else { return }
        state = .talk
        velocity.dx = 0
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    func endTalkPose() {
        guard state == .talk else { return }
        state = onFloor ? .idle : .fall
        currentAnimationTag = nil
        updateVisual()
    }

    /// Begin the Light Capsule armor-receive sequence. Mirrors Godot
    /// Capsule.gd:117 `play_animation_once("armor_receive")`. Auto-chains
    /// into `.armorBlink` after armorReceiveDuration, which itself returns
    /// to idle.
    func playArmorReceive() {
        guard state != .dead else { return }
        state = .armorReceive
        armorReceiveTimer = 0
        armorBlinkTimer = 0
        velocity = .zero
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    /// Trigger only the `armor_blink` segment (Godot Capsule.gd:128). Used
    /// for testing the second half independently of the receive pose.
    func playArmorBlink() {
        guard state != .dead else { return }
        state = .armorBlink
        armorBlinkTimer = 0
        velocity = .zero
        currentAnimationTag = nil
        updateVisual()
    }

    /// Mount the Ride Chaser stop pose (Godot Accelerate.gd `stop`). Held
    /// until `playRideStopEnd()` is called or the rider re-applies input.
    func playRideStop() {
        guard state != .dead else { return }
        state = .rideStop
        rideStopTimer = 0
        velocity.dx = 0
        currentAnimationTag = nil
        updateVisual()
    }

    /// Release the Ride Chaser stop pose (Godot Accelerate.gd `stop_end`).
    /// Auto-returns to idle/fall after rideStopEndDuration.
    func playRideStopEnd() {
        guard state != .dead else { return }
        state = .rideStopEnd
        rideStopEndTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    // MARK: - Future-stage poses (Aseprite-only in Sigma stage)

    private func tickCounter(_ dt: TimeInterval) {
        counterTimer += dt
        if counterTimer >= Player.counterDuration {
            counterTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    private func tickPunchDown(_ dt: TimeInterval) {
        punchDownTimer += dt
        if punchDownTimer >= Player.punchDownDuration {
            punchDownTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    private func tickStairsStart(_ dt: TimeInterval) {
        stairsStartTimer += dt
        if stairsStartTimer >= Player.stairsStartDuration {
            stairsStartTimer = 0
            // Auto-chain to the looping climb tag.
            state = .stairs
        }
    }

    private func tickStairsEnd(_ dt: TimeInterval) {
        stairsEndTimer += dt
        if stairsEndTimer >= Player.stairsEndDuration {
            stairsEndTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    private func tickAimShot(_ dt: TimeInterval) {
        aimShotTimer += dt
        if aimShotTimer >= Player.aimShotDuration {
            aimShotTimer = 0
            state = onFloor ? .idle : .fall
        }
    }

    /// Crouch pose. Plays the 3-frame transition once and holds the last
    /// frame until `endCrouch()` releases the player. Future-stage hook —
    /// Sigma's arena has no crouch trigger, but the tag exists for X8
    /// stages where dialogue or environmental cover lowers X's profile.
    func playCrouch() {
        guard state != .dead else { return }
        state = .crouch
        velocity.dx = 0
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    func endCrouch() {
        guard state == .crouch || state == .crouchTalk else { return }
        state = onFloor ? .idle : .fall
        currentAnimationTag = nil
        updateVisual()
    }

    /// Crouched dialogue lip-sync (loops the 2-frame `crouch_talk` tag
    /// while a crouched NPC line is streaming). Held until
    /// `endCrouchTalk()` returns the player to standing or in-air.
    func playCrouchTalk() {
        guard state != .dead else { return }
        state = .crouchTalk
        velocity.dx = 0
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    func endCrouchTalk() {
        guard state == .crouchTalk else { return }
        state = onFloor ? .idle : .fall
        currentAnimationTag = nil
        updateVisual()
    }

    /// Edge-balance pose (loops the 2-frame `balance` tag). Future-stage
    /// hook for ledges / narrow platforms. Held until `endBalance()` or
    /// the next state-changing input releases it.
    func playBalance() {
        guard state != .dead else { return }
        state = .balance
        velocity.dx = 0
        currentAnimationTag = nil
        updateVisual()
    }

    func endBalance() {
        guard state == .balance else { return }
        state = onFloor ? .idle : .fall
        currentAnimationTag = nil
        updateVisual()
    }

    /// Counter / parry move. Plays the 6-frame `counter` tag once and
    /// auto-returns. Future-stage hook for boss rematches that grant X
    /// the deflection ability.
    func playCounter() {
        guard state != .dead else { return }
        state = .counter
        counterTimer = 0
        velocity.dx = 0
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    /// Aerial down-punch. Plays the 6-frame `punch_down` tag once and
    /// auto-returns. Future-stage hook (Ride Armor stomp / down-special).
    func playPunchDown() {
        guard state != .dead else { return }
        state = .punchDown
        punchDownTimer = 0
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    /// Begin the ladder/stairs climb sequence. `stairs_start` plays for
    /// stairsStartDuration, then auto-chains to the looping `stairs`
    /// state. Call `endStairs()` to play the dismount.
    func playStairsStart() {
        guard state != .dead else { return }
        state = .stairsStart
        stairsStartTimer = 0
        velocity = .zero
        currentAnimationTag = nil
        updateVisual()
    }

    /// Force the looping climb tag without the start-frame transition
    /// (e.g. a save/load mid-climb).
    func playStairs() {
        guard state != .dead else { return }
        state = .stairs
        velocity = .zero
        currentAnimationTag = nil
        updateVisual()
    }

    /// Dismount the ladder. Plays the 2-frame `stairs_end` tag and
    /// auto-returns to idle/fall.
    func endStairs() {
        guard state == .stairs || state == .stairsStart else {
            // Allow direct dismount for the test harness.
            state = .stairsEnd
            stairsEndTimer = 0
            currentAnimationTag = nil
            updateVisual()
            return
        }
        state = .stairsEnd
        stairsEndTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    /// Aimed shot pose (Aseprite tags `shot_right`, `shot_left`,
    /// `shot_up`). Future-stage hook for stages that grant lock-on or
    /// 8-way aim. Plays once for aimShotDuration, then returns to idle.
    func playAimShot(direction: AimShotDirection) {
        guard state != .dead else { return }
        switch direction {
        case .right: state = .aimShotRight
        case .left:  state = .aimShotLeft
        case .up:    state = .aimShotUp
        }
        aimShotTimer = 0
        chargeLevel = 0
        chargeTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    /// Direction selector for `playAimShot(direction:)`.
    enum AimShotDirection {
        case right, left, up
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
        // Mirror Godot Modules/Intro.gd: a fresh spawn plays
        // beam → beam_in → beam_armor before returning to idle. The beam-in
        // tick is gated by tickIntro / the .beamIn early-return in tick().
        state = .beamIn
        beamInTimer = 0
        recoverTimer = 0
        visual.isHidden = false
        // Actor.heal saturates at maxHealth; explicit amount is safe even if
        // currentHealth was reduced to 0 by the prior death.
        heal(maxHealth)
        face(.right)
        deathTimer = 0
        deathSequenceBegun = false
        deathSecondBurstFired = false
        // Restore the per-life Godot Damage.gd export defaults: re-enable
        // the visible blink for the new life and refill the Last Chance
        // protection so the next fatal hit can be saved again.
        applyInvulnerabilityShader()
        deathProtection = 1
        hurtTimer = 0
        dashTimer = 0
        dashfall = false
        dashJump = false
        airDashTimer = 0
        airDashLetGoOfInput = false
        airDashInitialSign = 1
        dashWallJump = false
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
        recoverIsShooting = false
        armorReceiveTimer = 0
        armorBlinkTimer = 0
        damageResistTimer = 0
        rideStopTimer = 0
        rideStopEndTimer = 0
        counterTimer = 0
        punchDownTimer = 0
        stairsStartTimer = 0
        stairsEndTimer = 0
        aimShotTimer = 0
        currentAnimationTag = nil
        updateVisual()
    }

    // MARK: - Visuals

    private func updateVisual() {
        // Beam-in chains three tags by elapsed time. Mirrors Godot
        // Modules/Intro.gd which plays beam_in then beam_equip back-to-back.
        if state == .beamIn {
            let tag: String
            if beamInTimer < Player.beamPhaseEnd {
                tag = "beam"
            } else if beamInTimer < Player.beamInPhaseEnd {
                tag = "beam_in"
            } else {
                tag = "beam_armor"
            }
            playAnimation(tag, repeating: false)
            return
        }

        // Shot-pose / recover overlays briefly override grounded idle/walk
        // visuals. Both branches resolve to a Player.Action whose spec drives
        // the tag, so the same lookup path applies as for the state-derived
        // case below.
        if shotPoseTimer > 0 && (state == .idle || state == .walk || state == .walkStart) {
            playAction(shotPoseIsStrong ? .shotStrong : .shot)
            return
        }
        if recoverTimer > 0 && (state == .idle || state == .walk || state == .walkStart) {
            // Godot Armor.gd:128 swaps `recover` → `shot_recover` whenever
            // the trigger is still held when the recover frames begin.
            playAction(recoverIsShooting ? .shotRecover : .recover)
            return
        }

        // Special cases that don't have a 1:1 Action mapping:
        //   .dead  — sprite is hidden; explosion carries the visual.
        //   .beamIn — handled at the top of this method via beamInTimer.
        if state == .dead || state == .beamIn { return }

        // Resolve PlayerState → Player.Action then look up the spec.
        // `idle` swaps to `idleWeak` at low health (Godot IdleWeak.gd).
        let action = currentAction()
        playAction(action)
    }

    /// Map the internal state machine to the public Action enum, including
    /// the runtime-decided low-health idle swap. Kept as a method (not a
    /// computed property) because both inputs (state + isLowHealth) are
    /// read live; future ports can extend this with armor/weapon swaps.
    private func currentAction() -> Action {
        switch state {
        case .idle:         return isLowHealth ? .idleWeak : .idle
        case .walkStart:    return .walkStart
        case .walk:         return .walk
        case .jump:         return .jump
        case .fall:         return .fall
        case .dash:         return .dash
        case .airDash:      return .airDash
        case .slide:        return .slide
        case .wallJump:     return .wallJump
        case .hurt:         return .damage
        case .victory:      return .victory
        case .talk:         return .talk
        case .armorReceive: return .armorReceive
        case .armorBlink:   return .armorBlink
        case .damageResist: return .damageResist
        case .rideStop:     return .rideStop
        case .rideStopEnd:  return .rideStopEnd
        case .crouch:       return .crouch
        case .crouchTalk:   return .crouchTalk
        case .balance:      return .balance
        case .counter:      return .counter
        case .punchDown:    return .punchDown
        case .stairsStart:  return .stairsStart
        case .stairs:       return .stairs
        case .stairsEnd:    return .stairsEnd
        case .aimShotRight: return .shotRight
        case .aimShotLeft:  return .shotLeft
        case .aimShotUp:    return .shotUp
        // .dead / .beamIn are filtered out before this is called.
        case .dead, .beamIn: return .idle
        }
    }

    /// Play the animation declared in `actionSpecs[action]`. Used by
    /// `updateAnimationTag` and by the shot-pose / recover overlay branches.
    private func playAction(_ action: Action) {
        let spec = Player.spec(for: action)
        guard let tag = spec.tag else { return }
        playAnimation(tag, repeating: spec.loops)
    }

    // MARK: - Damage

    override func takeDamage(_ amount: CGFloat, inflicterX: CGFloat? = nil) -> Bool {
        // Godot Damage.gd `should_last_chance(actual_damage)`:
        //   character.current_health > 3 and death_protection > 0
        //   and character.current_health - actual_damage <= 0
        // → activate_last_chance(): clamp HP to 1, consume the protection.
        // Without this, sigmaLaserDamage (28) > playerMaxHealth (16) one-shots
        // even from full HP, which the user perceives as "died during
        // invincibility" — the lethal first hit lands before any iframe
        // window has a chance to feel relevant.
        var actualAmount = amount
        if !isInvulnerable, isAlive,
           currentHealth > 3, deathProtection > 0,
           currentHealth - amount <= 0 {
            actualAmount = currentHealth - 1
            deathProtection = 0
        }
        let applied = super.takeDamage(actualAmount, inflicterX: inflicterX)
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
            // Damage interrupts a dashfall / dashJump — Godot Fall._Interrupt
            // and Jump._Interrupt fire when Damage stages_in (conflicting
            // moves = "Anything"), clearing the 210 px/s preservation flags.
            dashfall = false
            dashJump = false
            chargeLevel = 0
            chargeTimer = 0
            // Damage interrupts WallJump / DashWallJump too — clear the carry
            // so the player isn't yanked at 210 px/s after stagger ends.
            dashWallJump = false
            // AirDash sticky letGo flag must reset alongside its timer so the
            // next air-dash isn't pre-cancelled by stale state.
            airDashLetGoOfInput = false
            spawnVFX(.damageSpark)
            flashWhite()
            if !isAlive {
                die()
            } else {
                state = .hurt
                AudioManager.shared.playSFX(AudioAssets.damage)
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
        dashfall = false
        dashJump = false
        dashWallJump = false
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
        currentAnimationTag = nil
        switch state {
        case .dash:         dashTimer = 999
        case .airDash:      airDashTimer = 999
        case .walkStart:    walkStartTimer = 999
        case .wallJump:     wallJumpTimer = 999
        case .beamIn:       beamInTimer = 0
        case .armorReceive: armorReceiveTimer = 0
        case .armorBlink:   armorBlinkTimer = 0
        case .damageResist: damageResistTimer = 0
        case .rideStop:     rideStopTimer = 0
        case .rideStopEnd:  rideStopEndTimer = 0
        case .counter:      counterTimer = 0
        case .punchDown:    punchDownTimer = 0
        case .stairsStart:  stairsStartTimer = 0
        case .stairsEnd:    stairsEndTimer = 0
        case .aimShotRight, .aimShotLeft, .aimShotUp:
            aimShotTimer = 0
        default:            break
        }
        updateVisual()
    }

    func debugRelease() {
        gravityScale = 1
        dashTimer = 0
        dashfall = false
        dashJump = false
        dashWallJump = false
        airDashTimer = 0
        airDashLetGoOfInput = false
        walkStartTimer = 0
        wallJumpTimer = 0
        shotPoseTimer = 0
        beamInTimer = 0
        recoverTimer = 0
        recoverIsShooting = false
        armorReceiveTimer = 0
        armorBlinkTimer = 0
        damageResistTimer = 0
        rideStopTimer = 0
        rideStopEndTimer = 0
        counterTimer = 0
        punchDownTimer = 0
        stairsStartTimer = 0
        stairsEndTimer = 0
        aimShotTimer = 0
        state = onFloor ? .idle : .fall
        updateVisual()
    }

    /// Test-harness hook that mirrors the natural death flow without needing
    /// to drain HP via contact damage. Applies a lethal takeDamage so the
    /// normal `die()` transition runs and `tickDeathSequence` ticks on
    /// subsequent frames. Used by `death_explosion.spec.ts` to assert
    /// sparkle animation without the ~15 s wait for Sigma contact damage.
    func debugKill() {
        // Drain last-chance protection first so the lethal hit lands rather
        // than clamping HP to 1. Without this, takeDamage's "should_last_chance"
        // branch keeps the player alive and the death sequence never starts.
        deathProtection = 0
        _ = takeDamage(.greatestFiniteMagnitude)
    }
}
