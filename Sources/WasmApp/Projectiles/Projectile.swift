import Foundation
import OpenSpriteKit

// MARK: - Projectile kind

enum ProjectileKind {
    case lemon          // Player base shot (charge 0)
    case mediumBuster   // Player charge level 1
    case chargedBuster  // Player charge level 2
    case sigmaBall      // Boss ground-combo wave
    case sigmaLance     // Boss lance throw
    case sigmaLaser     // Boss desperation beam
}

// MARK: - Projectile
// Manually-moved sprite node. No SKPhysicsBody — we do AABB vs hitboxes in BossBattleScene.

@MainActor
final class Projectile: SKSpriteNode {
    let kind: ProjectileKind
    var velocity: CGVector
    let damage: CGFloat
    let owner: ProjectileOwner
    private(set) var lifetime: TimeInterval
    private var age: TimeInterval = 0
    var isAlive: Bool = true

    // Visual-flip hint for stationary projectiles (velocity.dx == 0). For
    // moving projectiles the velocity sign drives the atlas flip in
    // `attachAtlas`; sigma_laser sits at the cannon mouth with zero velocity
    // and needs an explicit facing instead.
    var visualFacing: Facing?

    // Collision rect size — independent from the visual child's frame size so
    // the atlas art can be larger than the hit area (e.g. sigma_ball's 80x80
    // frame for a 14x14 hitbox).
    private let hitboxSize: CGSize
    private var visualChild: SKSpriteNode?

    // Stick-on-impact support. When `embedDuration > 0` the projectile freezes
    // at the impact point (player hit OR stage boundary) and self-destructs
    // after the duration elapses, instead of vanishing on contact.
    var embedDuration: TimeInterval = 0
    private(set) var isEmbedded: Bool = false
    private var embedTimer: TimeInterval = 0

    // Long-throw damage line — Godot Lance.tscn `DamageOnTouch2` (3×256 area at
    // lance-local (-5, -230)) deals damage along the throw path during state 0
    // (~0.3s after spawn) and is then deactivated when "loop" begins. Tracked
    // here as a line segment from `longDamageOrigin` (boss origin at throw
    // moment) to `position` (impact point) with a `longDamageWidth` half-width
    // (Godot Y-axis half = 128) measured along the segment from the impact end.
    var longDamageOrigin: CGPoint?
    var longDamageDuration: TimeInterval = 0
    var longDamageHalfLength: CGFloat = 0     // Godot DamageOnTouch2 size.y / 2 = 128
    var longDamageInnerOffset: CGFloat = 0    // Godot DamageOnTouch2 position.y = -230 → start 102 from impact
    var longDamageWidth: CGFloat = 0          // Godot DamageOnTouch2 size.x = 3 → 6 px total width
    var longDamageActive: Bool = false

    // Small tip hitbox — Godot Lance.tscn `DamageOnTouch` is active during
    // states 0+1 and deactivated at state 1→2 (timer > 2.0s). Without this
    // gate the embedded lance damages the player for the full 3.0s lifetime
    // instead of the Godot 2.0s window, giving an extra ~1s of vulnerability
    // post-loop where the spear is visually "fading out" but still hot.
    var tipDamageActive: Bool = true

    // Per-kind state machine for born-embedded projectiles. The lance lives 3s
    // total in Godot (state 0 ~0.3s + state 1 2s + state 2 1s) and triggers
    // particle/hitbox shutdowns at the boundaries; tracked here so the embed
    // path doesn't have to rely on SKAction sequences for game-logic timing.
    var lanceStateTimer: TimeInterval = 0
    var didStopLanceParticles: Bool = false
    /// Stop callback — set by the factory; invoked when state 1→2 transitions
    /// (timer > 2s) so emitter SKActions can be removed.
    var onLanceParticleStop: (() -> Void)?

    /// Local-space offset for the atlas-bound visual child. Godot Lance.tscn
    /// places `animatedSprite` at lance-local (0, -64) — i.e. 64 units toward
    /// the boss from the impact point — so the spear tip pokes only ~16 units
    /// past the wall instead of ~80 (sprite half-height). The Swift port
    /// mirrors that by offsetting the visual child via this property; the
    /// parent `position` stays at the impact point so collision math (`hitbox`,
    /// `isInsideLongDamage`) remains anchored there.
    var visualOffset: CGPoint = .zero

    enum ProjectileOwner {
        case player
        case boss
    }

    init(kind: ProjectileKind, position: CGPoint, velocity: CGVector, damage: CGFloat, owner: ProjectileOwner, size: CGSize, color: SKColor, lifetime: TimeInterval) {
        self.kind = kind
        self.velocity = velocity
        self.damage = damage
        self.owner = owner
        self.lifetime = lifetime
        self.hitboxSize = size
        super.init(texture: nil, color: color, size: size)
        self.position = position
        self.zPosition = 60
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tick(_ dt: TimeInterval, stageWidth: CGFloat, floorY: CGFloat) {
        // Born-embedded sigmaLance: drive Lance.gd's per-kind state machine
        // (state 0 long-damage → state 1 loop → state 2 end → free) without
        // moving the position. Lifetime is age-based (3s total).
        if kind == .sigmaLance && isEmbedded {
            age += dt
            lanceStateTimer += dt
            // State 0 → 1 at 0.3s (Godot "start" animation finishes ≈ 0.3s):
            // long_damage.deactivate() — stop the throw-line hitbox.
            if longDamageActive && lanceStateTimer >= 0.3 {
                longDamageActive = false
            }
            // State 1 → 2 at 2.0s: firetip + evilfire stop emitting,
            // damage.deactivate() halts the small tip damage too.
            if !didStopLanceParticles && lanceStateTimer >= 2.0 {
                didStopLanceParticles = true
                tipDamageActive = false
                onLanceParticleStop?()
            }
            // State 2 → free at 3.0s.
            if age >= lifetime { isAlive = false }
            return
        }

        // Generic embedded projectile (non-lance) — freeze in place, lifetime
        // controlled by embedTimer.
        if isEmbedded {
            embedTimer += dt
            if embedTimer >= embedDuration { isAlive = false }
            return
        }

        age += dt
        position.x += velocity.dx * CGFloat(dt)
        position.y += velocity.dy * CGFloat(dt)

        // Kill conditions.
        if age >= lifetime { isAlive = false; return }

        if embedDuration > 0 {
            // Stick-on-impact projectile (non-lance variants): clamp at the
            // boundary and embed instead of vanishing.
            let wallLeft: CGFloat = 16
            let wallRight: CGFloat = stageWidth - 16
            if position.x <= wallLeft {
                position.x = wallLeft
                embed()
            } else if position.x >= wallRight {
                position.x = wallRight
                embed()
            } else if position.y <= floorY {
                position.y = floorY
                embed()
            }
        } else {
            if position.x < -20 || position.x > stageWidth + 20 { isAlive = false }
            if position.y < floorY - 8 { isAlive = false }
        }
    }

    /// Test whether `point` lies within the long-throw damage rectangle. The
    /// rectangle is defined in lance-local coordinates and rotated/translated
    /// into world space here. Godot DamageOnTouch2 is at lance-local
    /// (-5, -230) with size (3, 256) — after `look_at(boss) + 90°`, the +Y
    /// axis points from impact toward boss, so the rectangle covers the throw
    /// segment from `innerOffset - halfLength` to `innerOffset + halfLength`
    /// distance from impact along the boss-direction axis.
    func isInsideLongDamage(_ point: CGPoint) -> Bool {
        guard longDamageActive, let origin = longDamageOrigin else { return false }
        let dx = origin.x - position.x
        let dy = origin.y - position.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.001 else { return false }
        let ax = dx / length    // unit vector from impact toward boss origin
        let ay = dy / length
        // Project (point - position) onto axis.
        let px = point.x - position.x
        let py = point.y - position.y
        let along = px * ax + py * ay
        // Perpendicular distance.
        let perp = abs(-px * ay + py * ax)
        let nearEdge = longDamageInnerOffset - longDamageHalfLength
        let farEdge = longDamageInnerOffset + longDamageHalfLength
        // Clip to actual throw distance — the rectangle terminates at the boss
        // origin, not 358 px out, if the boss is closer than that.
        let farClipped = min(farEdge, length)
        return along >= nearEdge && along <= farClipped && perp <= (longDamageWidth / 2)
    }

    /// Freeze the projectile in place. Called by the collision resolver on
    /// player contact and by `tick` on stage-boundary contact.
    func embed() {
        guard !isEmbedded else { return }
        velocity = .zero
        isEmbedded = true
        embedTimer = 0
    }

    /// Mark the projectile embedded at construction time without resetting
    /// timers — used by `sigmaLance` factory which models Godot's
    /// teleport-to-wall lance as "born embedded at the impact point".
    func markBornEmbedded() {
        isEmbedded = true
    }

    /// Distance from boss origin to impact point, captured at spawn for
    /// `hide_far_trails` (Lance.gd:28-35) — trails 3+4 hide if <170 px,
    /// trail 4 hides if 170 ≤ d < 280.
    var lanceDistanceFromOrigin: CGFloat = 0

    /// Visual-only hitbox uses the fixed collision size so atlas art doesn't
    /// inflate the hit radius.
    var hitbox: CGRect {
        CGRect(x: position.x - hitboxSize.width / 2, y: position.y - hitboxSize.height / 2,
               width: hitboxSize.width, height: hitboxSize.height)
    }

    // MARK: - Atlas

    /// Attach a sprite atlas and start looping the named tag. The visual is a
    /// child node so the parent `size` (and therefore `hitbox`) stays authoritative.
    func attachAtlas(_ atlas: SpriteAtlas, tag: String, visualSize: CGSize, repeating: Bool = true) {
        guard let anim = atlas.animation(tag) else { return }
        let child: SKSpriteNode
        if let existing = visualChild {
            child = existing
            child.size = visualSize
            child.position = visualOffset
        } else {
            child = SKSpriteNode(texture: nil, size: visualSize)
            child.position = visualOffset
            child.zPosition = 0.1
            child.colorBlendFactor = 0
            addChild(child)
            visualChild = child
        }
        // Hide the placeholder color rect once real art is bound.
        // DEBUG: leave the parent tint so we can see where it actually renders.
        // self.colorBlendFactor = 0

        // Mirror visual when flying left — atlases are authored facing right.
        // Skip the flip when the parent projectile has a non-zero zRotation:
        // that rotation already aligns the sprite with the velocity vector
        // (e.g. the angled sigma lance), so adding an X mirror would leave
        // the art backwards.
        let parentRotated = abs(self.zRotation) > 0.001
        if !parentRotated {
            if velocity.dx < 0 {
                child.xScale = -abs(child.xScale)
            } else if velocity.dx > 0 {
                child.xScale = abs(child.xScale)
            } else if let f = visualFacing {
                // sigma_laser atlas natively depicts a LEFT-firing beam
                // (muzzle on the texture's right edge, body extending left).
                // Mirror only when firing RIGHT.
                child.xScale = -f.sign * abs(child.xScale)
            }
        }

        child.texture = anim.textures[0]
        if anim.textures.count == 1 { return }
        let action = SKAction.animate(with: anim.textures, timePerFrame: anim.timePerFrame)
        let runner = repeating ? SKAction.repeatForever(action) : action
        child.run(runner, withKey: "anim")
    }
}

// MARK: - Factory helpers

@MainActor
enum ProjectileFactory {
    static func lemon(from: CGPoint, facing: Facing) -> Projectile {
        Projectile(
            kind: .lemon,
            position: from,
            velocity: CGVector(dx: facing.sign * WeaponConstants.lemonSpeed, dy: 0),
            damage: WeaponConstants.lemonDamage,
            owner: .player,
            size: CGSize(width: 8, height: 6),
            color: SKColor(red: 1.0, green: 0.95, blue: 0.3, alpha: 1.0),
            lifetime: WeaponConstants.lemonLifetime * 3  // extended vs Godot "off-screen 0.4s"
        )
    }

    static func mediumBuster(from: CGPoint, facing: Facing) -> Projectile {
        Projectile(
            kind: .mediumBuster,
            position: from,
            velocity: CGVector(dx: facing.sign * WeaponConstants.mediumBusterSpeed, dy: 0),
            damage: WeaponConstants.mediumBusterDamage,
            owner: .player,
            size: CGSize(width: 14, height: 10),
            color: SKColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1.0),
            lifetime: WeaponConstants.mediumBusterLifetime
        )
    }

    static func chargedBuster(from: CGPoint, facing: Facing) -> Projectile {
        Projectile(
            kind: .chargedBuster,
            position: from,
            velocity: CGVector(dx: facing.sign * WeaponConstants.chargedBusterSpeed, dy: 0),
            damage: WeaponConstants.chargedBusterDamage,
            owner: .player,
            size: CGSize(width: 22, height: 18),
            color: SKColor(red: 0.95, green: 0.9, blue: 0.4, alpha: 1.0),
            lifetime: WeaponConstants.chargedBusterLifetime
        )
    }

    static func sigmaBall(from: CGPoint, targetX: CGFloat) -> Projectile {
        let direction: CGFloat = targetX < from.x ? -1 : 1
        return Projectile(
            kind: .sigmaBall,
            position: from,
            velocity: CGVector(dx: direction * WeaponConstants.sigmaBallSpeed, dy: 0),
            damage: WeaponConstants.sigmaBallDamage,
            owner: .boss,
            size: CGSize(width: 14, height: 14),
            color: SKColor(red: 1.0, green: 0.35, blue: 0.2, alpha: 1.0),
            lifetime: 3.0
        )
    }

    /// Projectile aimed at a point using the normalized direction vector.
    /// Source: Godot `instantiate_projectile` — `proj.speed * multiplier * target_dir`
    /// where target_dir = (player - boss).normalized(). Multiplier is 1.25 for
    /// AirCombo, 1.5 for GroundCombo.slash3.
    static func sigmaBallAimed(from origin: CGPoint, target: CGPoint, speedMultiplier: CGFloat) -> Projectile {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let distance = max(1, sqrt(dx * dx + dy * dy))
        let speed = WeaponConstants.sigmaBallSpeed * speedMultiplier
        return Projectile(
            kind: .sigmaBall,
            position: origin,
            velocity: CGVector(dx: (dx / distance) * speed, dy: (dy / distance) * speed),
            damage: WeaponConstants.sigmaBallDamage,
            owner: .boss,
            size: CGSize(width: 14, height: 14),
            color: SKColor(red: 1.0, green: 0.35, blue: 0.2, alpha: 1.0),
            lifetime: 3.0
        )
    }

    static func sigmaLance(impact: CGPoint, bossBody: CGPoint, bossOrigin: CGPoint) -> Projectile {
        // Faithful port of Godot LanceThrow.gd `instantiate_spear()` +
        // Lance.gd lifecycle:
        //   • lance.global_position = lance_raycast.get_collision_point()
        //   • lance.look_at(character.global_position); rotation_degrees += 90
        //     (`character` is the SIGMA BOSS — not the player)
        //   • lifetime = ~3s (state 0 ~0.3s + state 1 2s + state 2 1s)
        //   • DamageOnTouch (small tip, 3×112 at lance-local (-5, -46))
        //     active states 0–1, deactivated at state 1→2
        //   • DamageOnTouch2 (long throw line, 3×256 at lance-local (-5, -230))
        //     active state 0 only, deactivated at state 0→1 (~0.3s)
        // The lance is born EMBEDDED at the impact point — there is no flight.
        // The trail sprites attached by `attachLanceOverlays` (FAR-FIRST stagger)
        // produce the visual "throw streak" illusion in Lance.tscn instead.
        //
        // `bossBody`  = boss CharacterBody2D global position (Godot
        //               `character.global_position`, no marker offset). Used
        //               for the lance's `look_at` rotation reference.
        // `bossOrigin` = boss + lance_pos marker offset. Used as the raycast
        //               origin and as the long-throw damage segment origin.
        let bdx = impact.x - bossBody.x
        let bdy = impact.y - bossBody.y
        let distance = max(1, sqrt(bdx * bdx + bdy * bdy))
        let lance = Projectile(
            kind: .sigmaLance,
            position: impact,
            velocity: .zero,
            damage: WeaponConstants.sigmaLanceDamage,
            owner: .boss,
            size: CGSize(width: 14, height: 42),
            color: SKColor(red: 0.85, green: 0.65, blue: 0.1, alpha: 1.0),
            lifetime: 3.0   // Godot Lance.gd: state 0 ~0.3s + state 1 2s + state 2 1s
        )
        // The lance is an arrow the boss threw at the player and stuck into
        // the wall/floor at `impact`. TIP (V-blade) is AT the impact point;
        // TAIL (thin shaft) extends back toward the boss.
        //
        // sigma_lance.png frame 4 (the fully-extended throw frame) layout:
        //   - thin 3-px shaft from PNG y≈36 down to y≈100 (TAIL side)
        //   - wide V-blade from PNG y≈104 to y≈142 (TIP side)
        //   So PNG-top = TAIL (shaft), PNG-bottom = TIP (V-blade).
        //
        // SpriteKit Y-up + V-flipped texture sampling means an unrotated
        // SKSpriteNode shows PNG-top at sprite-local +Y. So unrotated:
        //   sprite-local +Y → TAIL,  sprite-local -Y → TIP.
        //
        // We want the rotated sprite's +Y to point toward the boss (TAIL toward
        // boss, TIP into wall). Important quirk: OpenCoreAnimation's
        // `CATransform3DMakeRotation` produces Apple CALayer's matrix
        //   (m11=cos, m12=sin, m21=-sin, m22=cos)
        // which, applied in OpenCoreAnimation's Y-UP coordinate system, rotates
        // CLOCKWISE for positive angles — opposite to Apple SpriteKit's CCW
        // convention. With that convention, sprite-local +Y rotated by θ ends
        // up at world (sin θ, cos θ), so to align with toward-boss = (boss -
        // impact)/L = (-bdx/L, -bdy/L) we solve sin θ = -bdx/L, cos θ = -bdy/L,
        // giving θ = atan2(-bdx, -bdy) = atan2(boss.x - impact.x,
        // boss.y - impact.y).
        lance.zRotation = atan2(-bdx, -bdy)
        // Godot Lance.tscn animatedSprite at lance-local (0, -64); after
        // `look_at(boss) + 90°` the Godot lance-local -Y points toward boss,
        // so the sprite center sits 64 px toward boss. In Swift our local +Y
        // points toward boss after the rotation above, so the equivalent
        // offset is (0, +64). The TIP edge (sprite-local -Y) ends up at +64
        // - 80 = -16 = 16 px past the impact into the wall. The TAIL edge
        // ends up at +64 + 80 = 144 px back toward the boss.
        lance.visualOffset = CGPoint(x: 0, y: 64)
        // Born embedded — no flight, no boundary clamp. The lance is at the
        // wall from frame 1 and will self-destruct at age 3s.
        lance.velocity = .zero
        // Engage long-throw damage along the segment from impact back toward
        // boss origin. Godot DamageOnTouch2: position.y = -230, size.y = 256
        // (so half-length 128), size.x = 3 (width 6, half 3). After look_at +
        // 90°, +Y axis = toward boss; the rectangle's centre is 230 px along
        // that axis, ±128 along it = the segment [102, 358] from impact end.
        lance.longDamageOrigin = bossOrigin
        lance.longDamageDuration = 0.3
        lance.longDamageHalfLength = 128
        lance.longDamageInnerOffset = 230
        lance.longDamageWidth = 6
        lance.longDamageActive = true
        // Match the embedded-lifetime path inside `tick`.
        lance.velocity = .zero
        // Force the embed state without touching `embed()` (which would also
        // zero longDamageOrigin if invoked elsewhere).
        lance.markBornEmbedded()
        // Distance hint used by attachLanceOverlays for hide_far_trails.
        lance.lanceDistanceFromOrigin = distance
        return lance
    }

    static func sigmaLaser(from: CGPoint, facing: Facing) -> Projectile {
        // Stationary beam pinned to the cannon mouth. sigma_laser.png is a
        // 4x4 atlas (15 frames at 398x208) with `cannon_loop` as the
        // persistent animation. Godot SigmaLaser.tscn anchors the node at
        // the boss's muzzle and offsets the sprite by (-199, -6) so the
        // muzzle (atlas right edge) sits at `from.x` and the body extends
        // 398 px into the facing direction. Match that layout here: the
        // Projectile parent sits at the beam midpoint (boss muzzle minus
        // half the atlas width along the facing axis). Hitbox height is
        // deliberately narrower than the visual atlas so the damage rect
        // tracks the beam core rather than the glow halo.
        let laser = Projectile(
            kind: .sigmaLaser,
            position: CGPoint(x: from.x + facing.sign * 199, y: from.y),
            velocity: .zero,
            damage: WeaponConstants.sigmaLaserDamage,
            owner: .boss,
            size: CGSize(width: 398, height: 32),
            color: SKColor.clear,
            lifetime: 2.4
        )
        laser.visualFacing = facing
        return laser
    }
}
