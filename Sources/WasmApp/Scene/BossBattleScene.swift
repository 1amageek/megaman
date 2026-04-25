import Foundation
#if arch(wasm32)
import JavaScriptKit
#endif
import OpenSpriteKit

// MARK: - BossBattleScene
// Wires together Player, Boss, BossAI, projectiles, HUD, and collision.

@MainActor
final class BossBattleScene: SKScene {
    enum Phase {
        case intro
        case fighting
        case victory
        case defeat
        case gameOver
    }

    /// Godot GlobalVariables[`player_lives`] default is 2 on a fresh save —
    /// the player gets three attempts total (initial + 2 retries) before the
    /// game-over screen triggers.
    static let startingLives: Int = 2

    fileprivate let stage: Stage
    private let input: InputManager
    private(set) var player: Player
    private(set) var boss: Boss
    private(set) var bossAI: BossAI!
    private var bossHealthBar: HealthBar!
    private var playerHealthBar: HealthBar!
    private var projectiles: [Projectile] = []
    private var lastUpdateTime: TimeInterval?
    private(set) var phase: Phase = .intro
    private var phaseTimer: TimeInterval = 0
    private(set) var playerLives: Int = BossBattleScene.startingLives
    private var fadeOverlay: SKSpriteNode?
    private var gameOverLabel: SKLabelNode?
    private var fpsLabel: SKLabelNode?
    private var fpsSmoothed: Double = 0
    private var nextDiagnosticLogTime: TimeInterval = 30.0
    private var backdrop: StageBackdrop!
    private var sigmaIntro: SigmaIntro!
    private var sigmaWalls: [SigmaWall] = []
    // Godot `screenshake()` — brief positional jitter during throne destruction.
    // Applied to the backdrop node so the effect reads as camera shake without
    // mutating actor logical positions (which would misalign collisions).
    private var screenShakeTimer: TimeInterval = 0
    private var screenShakeAmplitude: CGFloat = 0

    // Victory cadence — Godot BossDeath drives a 6-stage tempo over an
    // ~13 s window (1 s freeze + 10 s explosions + 3.12 s fade). The port
    // collapses the tempo into wall-clock thresholds against `phaseTimer`,
    // gated by a per-burst accumulator so explosions emit at the same
    // ~0.45 s cadence Godot's particle process runs at.
    private var victoryBurstAccumulator: TimeInterval = 0
    private var victoryFlashFired: Bool = false
    private var victoryBossHidden: Bool = false
    static let victoryFreeze: TimeInterval = 1.0
    static let victoryExplosionEnd: TimeInterval = 11.0
    static let victoryFlashEnd: TimeInterval = 11.45
    static let victoryFadeEnd: TimeInterval = 14.0
    static let victoryBurstInterval: TimeInterval = 0.45

    private(set) var playerAtlas: SpriteAtlas?
    private var projectileAtlases: [ProjectileKind: SpriteAtlas] = [:]

    var liveProjectileCount: Int { projectiles.lazy.filter { $0.isAlive }.count }
    var totalProjectileCount: Int { projectiles.count }
    var deadProjectileCount: Int { projectiles.lazy.filter { !$0.isAlive }.count }
    var playerProjectileCount: Int {
        projectiles.lazy.filter { $0.owner == .player && $0.isAlive }.count
    }
    var bossProjectileCount: Int {
        projectiles.lazy.filter { $0.owner == .boss && $0.isAlive }.count
    }
    var currentFPS: Double { fpsSmoothed }
    var phaseName: String {
        switch phase {
        case .intro: return "intro"
        case .fighting: return "fighting"
        case .victory: return "victory"
        case .defeat: return "defeat"
        case .gameOver: return "gameOver"
        }
    }

    fileprivate var stageWidth: CGFloat { stage.width }

    init(stage: Stage = .bossArena, input: InputManager = .shared) {
        self.stage = stage
        self.input = input
        self.player = Player()
        self.boss = Boss()
        super.init(size: CGSize(width: stage.width, height: stage.height))
        self.anchorPoint = .zero
        self.backgroundColor = SKColor.black
    }

    /// Inject sprite atlases after async load completes. Safe to call before or after didMove(to:).
    func attachPlayerAtlas(_ atlas: SpriteAtlas) {
        self.playerAtlas = atlas
        player.attachAtlas(atlas)
    }

    func attachBossAtlas(_ atlas: SpriteAtlas) {
        boss.attachAtlas(atlas)
    }

    /// Register a projectile atlas for a kind. Spawned projectiles of that
    /// kind automatically bind the atlas on creation.
    func attachProjectileAtlas(_ atlas: SpriteAtlas, for kind: ProjectileKind) {
        projectileAtlases[kind] = atlas
    }

    /// Register a charge-overlay atlas. Level 1 corresponds to mid-charge
    /// (Godot `ChargingParticle`), Level 2 to full charge (`ChargedParticle`).
    func attachChargeAtlas(_ atlas: SpriteAtlas, for level: Int) {
        player.attachChargeAtlas(atlas, for: level)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        MainActor.assumeIsolated {
            buildScene()
        }
    }

    private func buildScene() {
        backdrop = StageBackdrop(stage: stage)
        addChild(backdrop)

        player.position = stage.playerSpawn
        player.battleScene = self
        addChild(player)

        boss.position = stage.bossSpawn
        boss.face(.left)
        addChild(boss)

        playerHealthBar = HealthBar(kind: .player, maxValue: player.maxHealth)
        playerHealthBar.position = CGPoint(x: 14, y: stage.height - 40)
        playerHealthBar.zPosition = 100
        addChild(playerHealthBar)

        bossHealthBar = HealthBar(kind: .boss, maxValue: boss.maxHealth)
        bossHealthBar.position = CGPoint(x: stage.width - 14, y: stage.height - 40)
        bossHealthBar.zPosition = 100
        // Godot HUD.gd: `boss_bar.visible = false` on scene load; the bar
        // fades in only when Intro emits `boss_health_appear` at stage 6.
        bossHealthBar.alpha = 0
        bossHealthBar.startFillAnimation(to: 0, duration: 0)
        addChild(bossHealthBar)

        // SigmaWalls — placed just inside the existing 8 px decorative wall
        // ribbons so the activation visually fills the same edge channels.
        // Godot pillars sit ~14% from the arena centre on each side; with our
        // 398 px stage that puts the pillar centres at x=16 (left, dir=-1) and
        // x=stage.width - 16 (right, dir=+1). Hidden until intro stage 4.
        let leftWall = SigmaWall(direction: -1)
        leftWall.position = CGPoint(x: 16, y: stage.floorY)
        addChild(leftWall)
        let rightWall = SigmaWall(direction: 1)
        rightWall.position = CGPoint(x: stage.width - 16, y: stage.floorY)
        addChild(rightWall)
        sigmaWalls = [leftWall, rightWall]

        bossAI = BossAI(context: SceneAttackContext(scene: self))
        sigmaIntro = SigmaIntro(scene: self, boss: boss)
        sigmaIntro.begin()

        let label = SKLabelNode(fontNamed: "Menlo")
        label.fontSize = 10
        label.fontColor = .white
        label.text = "FPS --"
        label.position = CGPoint(x: stage.width / 2, y: 6)
        label.zPosition = 200
        addChild(label)
        fpsLabel = label
    }

    // MARK: - Tick

    override func update(_ currentTime: TimeInterval) {
        // WASM is single-threaded; requestAnimationFrame always fires on the main thread.
        MainActor.assumeIsolated {
            let dt: TimeInterval
            if let last = lastUpdateTime {
                dt = min(1.0 / 30.0, currentTime - last)
            } else {
                dt = 1.0 / 60.0
            }
            lastUpdateTime = currentTime

            if isPaused { return }

            switch phase {
            case .intro:
                // Godot Intro.gd drives a 9-stage cutscene that ends by emitting
                // `intro_concluded`, which BossAI.gd listens for to activate.
                // SigmaIntro.onIntroConcluded flips phase → .fighting and
                // activates the AI. During the cutscene we still tick physics
                // so boss/player settle onto the floor, but player input and
                // boss attacks are gated off (player.tick + collisions are
                // skipped and bossAI.tick isn't called).
                sigmaIntro.tick(dt)
                tickSigmaWalls(dt)
                bossHealthBar.tickFillAnimation(dt)
                tickScreenShake(dt)
            case .fighting:
                player.tick(dt, input: input, stageWidth: stage.width, floorY: stage.floorY)
                boss.tick(dt, stageWidth: stage.width, floorY: stage.floorY)
                bossAI.tick(dt)
                tickSigmaWalls(dt)
                tickProjectiles(dt)
                resolveCollisions()
                if !player.isAlive { enterDefeat() }
                if !boss.isAlive { enterVictory() }
            case .defeat:
                phaseTimer += dt
                player.tick(dt, input: input, stageWidth: stage.width, floorY: stage.floorY)
                tickSigmaWalls(dt)
                tickProjectiles(dt)
                updateDefeatFade()
                // Godot GameManager.on_death is called from PlayerDeath._Update
                // at timer > 5.0; we mirror that wall-clock gate so the fade
                // and explosion cadence have time to read before the reset.
                if phaseTimer >= 5.0 { onPlayerDeath() }
            case .victory:
                phaseTimer += dt
                player.tick(dt, input: input, stageWidth: stage.width, floorY: stage.floorY)
                tickSigmaWalls(dt)
                tickProjectiles(dt)
                tickVictorySequence(dt)
            case .gameOver:
                phaseTimer += dt
                // Godot `game_over` → go_to_stage_select jumps out of the battle
                // scene entirely. The E2E port has no outer shell to return to,
                // so we hold the Game Over screen for 3 s then reset everything
                // (lives + phase) to re-enter the intro loop.
                if phaseTimer >= 3.0 { resetGame() }
            }

            playerHealthBar.update(current: player.currentHealth)
            bossHealthBar.update(current: boss.currentHealth)
            input.endFrame()

            if dt > 0 {
                let instant = 1.0 / Double(dt)
                fpsSmoothed = fpsSmoothed == 0 ? instant : fpsSmoothed * 0.9 + instant * 0.1
                fpsLabel?.text = "FPS \(Int(fpsSmoothed.rounded()))"
            }

            logDiagnosticsIfNeeded(at: currentTime)
        }
    }

    func resetTimeline() {
        lastUpdateTime = nil
    }

    private func logDiagnosticsIfNeeded(at currentTime: TimeInterval) {
        guard currentTime >= nextDiagnosticLogTime else { return }
        logDiagnostics(at: currentTime)
        let completedIntervals = floor(currentTime / 30.0)
        nextDiagnosticLogTime = (completedIntervals + 1.0) * 30.0
    }

    private func logDiagnostics(at currentTime: TimeInterval) {
        let stats = SKDiagnostics.shared.snapshot(scene: self)
        print(
            "[MegamanDiagnostics] " +
            "t=\(formatDiagnostic(currentTime)) " +
            "phase=\(phaseName) " +
            "phaseTimer=\(formatDiagnostic(phaseTimer)) " +
            "fps=\(formatDiagnostic(fpsSmoothed)) " +
            "sceneChildren=\(children.count) " +
            "totalNodes=\(stats.nodeCount) " +
            "projectiles=\(totalProjectileCount) " +
            "liveProjectiles=\(liveProjectileCount) " +
            "deadProjectiles=\(deadProjectileCount) " +
            "playerProjectiles=\(playerProjectileCount) " +
            "bossProjectiles=\(bossProjectileCount) " +
            "runningActions=\(stats.runningActionCount) " +
            "actionBuckets=\(stats.actionNodeBucketCount) " +
            "orphanedActionBuckets=\(stats.orphanedActionNodeBucketCount) " +
            "textures=\(stats.textureCount) " +
            "gpuTextures=\(stats.gpuTextureCount) " +
            "emitters=\(stats.emitterCount) " +
            "particles=\(stats.particleCount) " +
            "debugMarkers=\(debugMarkers.count) " +
            "resources=\"\(stats.resourceCounts)\"" +
            diagnosticHeapSuffix()
        )
    }

    private func formatDiagnostic(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func diagnosticHeapSuffix() -> String {
        #if arch(wasm32)
        guard let memory = JSObject.global.performance.memory.object else {
            return ""
        }
        let used = Int(memory.usedJSHeapSize.number ?? 0)
        let total = Int(memory.totalJSHeapSize.number ?? 0)
        let limit = Int(memory.jsHeapSizeLimit.number ?? 0)
        return " jsHeapUsed=\(used) jsHeapTotal=\(total) jsHeapLimit=\(limit)"
        #else
        return ""
        #endif
    }

    // MARK: - Projectiles

    func spawnPlayerShot(chargeLevel: Int, from origin: CGPoint, facing: Facing) {
        // Mirrors Godot Buster.tscn shots[chargeLevel]: [Lemon, Medium Buster, Charged Buster].
        // Godot limits each charge tier independently; we keep a shared player-projectile
        // cap so the player can't flood the scene — uses the lemon cap for all tiers.
        let alive = projectiles.filter { $0.owner == .player && $0.isAlive }.count
        guard alive < WeaponConstants.maxLemonsAlive else { return }
        let projectile: Projectile
        switch chargeLevel {
        case 2:  projectile = ProjectileFactory.chargedBuster(from: origin, facing: facing)
        case 1:  projectile = ProjectileFactory.mediumBuster(from: origin, facing: facing)
        default: projectile = ProjectileFactory.lemon(from: origin, facing: facing)
        }
        spawnProjectile(projectile)
    }

    func spawnProjectile(_ projectile: Projectile) {
        projectiles.append(projectile)
        addChild(projectile)
        if let atlas = projectileAtlases[projectile.kind] {
            projectile.attachAtlas(
                atlas,
                tag: Self.defaultAnimationTag(for: projectile.kind),
                visualSize: Self.defaultVisualSize(for: projectile.kind)
            )
        }
        // Lance.tscn ships as a composite of (animatedSprite + 4 trail
        // AnimatedSprite2D + firetip GPUParticles2D + evilfire GPUParticles2D).
        // Port the visible nodes the same way: attach trail + particle
        // children that ride along with the lance and freeze with it on
        // embed (children inherit the parent's transform / removal).
        if projectile.kind == .sigmaLance {
            BossEffects.attachLanceOverlays(to: projectile)
        }
    }

    // Test-only: clear all boss-owned projectiles. Used with `bossAI.deactivate()`
    // so input tests see a clean stage.
    func clearBossProjectiles() {
        for p in projectiles where p.owner == .boss {
            p.removeFromParent()
        }
        projectiles.removeAll { $0.owner == .boss }
    }

    // MARK: - Projectile atlas defaults
    // Each projectile kind has one canonical "alive" animation; boss lance
    // lives on a separate atlas so its loop tag differs. See each JSON for
    // authoritative names.

    private static func defaultAnimationTag(for kind: ProjectileKind) -> String {
        switch kind {
        case .lemon:         return "Tag"    // lemon.json
        case .mediumBuster:  return "loop"   // medium_shot.json
        case .chargedBuster: return "Tag"    // heavy_shot.json
        case .sigmaBall:     return "evilfire_loop"
        case .sigmaLance:    return "loop"
        case .sigmaLaser:    return "cannon_loop"
        }
    }

    private static func defaultVisualSize(for kind: ProjectileKind) -> CGSize {
        switch kind {
        case .lemon:         return CGSize(width: 32, height: 32)   // lemon.png frame
        case .mediumBuster:  return CGSize(width: 48, height: 48)   // medium_shot.png frame
        case .chargedBuster: return CGSize(width: 64, height: 64)   // heavy_shot.png frame
        case .sigmaBall:     return CGSize(width: 80, height: 80)
        case .sigmaLance:    return CGSize(width: 32, height: 160)
        case .sigmaLaser:    return CGSize(width: 398, height: 208)
        }
    }

    private func tickProjectiles(_ dt: TimeInterval) {
        for projectile in projectiles where projectile.isAlive {
            projectile.tick(dt, stageWidth: stage.width, floorY: stage.floorY)
        }
        // Remove dead projectiles
        projectiles.removeAll { projectile in
            if !projectile.isAlive {
                projectile.removeFromParent()
                return true
            }
            return false
        }
    }

    // MARK: - Collisions

    private func resolveCollisions() {
        for projectile in projectiles where projectile.isAlive {
            switch projectile.owner {
            case .player:
                if boss.isAlive, projectile.hitbox.intersects(boss.hitbox) {
                    boss.takeDamage(projectile.damage, inflicterX: projectile.position.x)
                    if projectile.kind == .lemon { projectile.isAlive = false }
                }
            case .boss:
                if player.isAlive, projectile.hitbox.intersects(player.hitbox) {
                    _ = player.takeDamage(projectile.damage, inflicterX: projectile.position.x)
                    switch projectile.kind {
                    case .sigmaLaser:
                        break  // beam persists for the full firing window
                    case .sigmaLance:
                        // Lance is born embedded at the wall; small DamageOnTouch
                        // tip is active until state 1→2 (~2 s). Player iframes
                        // (~1.15 s) keep the per-frame overlap check from
                        // re-damaging through the full window.
                        break
                    default:
                        projectile.isAlive = false
                    }
                }
                // Long-throw damage line — Godot Lance.tscn `DamageOnTouch2`
                // (3×256 area at lance-local (-5, -230)) is active for state 0
                // only (~0.3 s after spawn) and covers the segment from the
                // impact end back toward the boss. Independent from the small
                // tip hitbox above; player iframes prevent double-charging.
                if player.isAlive,
                   projectile.kind == .sigmaLance,
                   projectile.longDamageActive,
                   projectile.isInsideLongDamage(player.position) {
                    _ = player.takeDamage(
                        WeaponConstants.sigmaLanceDamage,
                        inflicterX: projectile.position.x
                    )
                }
            }
        }

        // Boss melee hitbox vs player — inflicter is the boss body.
        if let attack = boss.activeAttack, let hitbox = attack.currentHitbox {
            if hitbox.intersects(player.hitbox) {
                _ = player.takeDamage(attack.hitboxDamage, inflicterX: boss.position.x)
            }
        }

        // Bodies touching — passive contact damage. Godot Sigma.tscn DamageOnTouch
        // node sets damage = 8.0; matches that exactly.
        if boss.isAlive, boss.hitbox.intersects(player.hitbox), !boss.isAttacking {
            _ = player.takeDamage(WeaponConstants.sigmaContactDamage, inflicterX: boss.position.x)
        }

        // Player-vs-SigmaWall — push the player out of any active wall AABB.
        // Godot resolves this via StaticBody2D collision; since the port runs
        // a manual physics step, we snap the player to the wall's inner edge
        // along the wall.direction axis and zero the inward velocity component
        // so wall-jump / dash inputs read as wall-contact for one frame.
        for wall in sigmaWalls {
            guard let wallHB = wall.hitbox else { continue }
            let playerHB = player.hitbox
            guard playerHB.intersects(wallHB) else { continue }
            if wall.direction > 0 {
                // Right-side wall — keep player to the LEFT of it.
                let limit = wallHB.minX - player.size.width / 2
                if player.position.x > limit {
                    player.position.x = limit
                    if player.velocity.dx > 0 { player.velocity.dx = 0 }
                }
            } else {
                // Left-side wall — keep player to the RIGHT of it.
                let limit = wallHB.maxX + player.size.width / 2
                if player.position.x < limit {
                    player.position.x = limit
                    if player.velocity.dx < 0 { player.velocity.dx = 0 }
                }
            }
        }
    }

    private func tickSigmaWalls(_ dt: TimeInterval) {
        for wall in sigmaWalls { wall.tick(dt) }
    }

    /// Mirrors Godot Intro.gd stage 4 `Event.emit_signal("sigma_walls")` —
    /// SigmaWall.gd `activate()` arms the rise tween on every listening wall.
    func activateSigmaWalls() {
        for wall in sigmaWalls { wall.activate() }
    }

    /// Side of any active `SigmaWall` the player's hitbox is touching, or
    /// `nil` if neither wall is in reach. Player calls this each frame so
    /// `wallContact` extends beyond stage edges to the inner pillars — without
    /// it, slide / wall-jump only fire at the stage borders and Sigma's
    /// arena pillars feel like invisible push-out walls instead of climbable
    /// surfaces.
    func sigmaWallContact(for playerHitbox: CGRect) -> Facing? {
        for wall in sigmaWalls {
            guard let wallHB = wall.hitbox else { continue }
            // Vertical overlap is required — the wall is a pillar, not a floor.
            let yOverlap = playerHitbox.maxY > wallHB.minY && playerHitbox.minY < wallHB.maxY
            guard yOverlap else { continue }
            // Player.tick runs updateWallContact BEFORE scene.resolveCollisions,
            // so during a frame in which the player is pressing into the wall
            // their integrated hitbox can overshoot into the wall AABB by
            // (walkSpeed * dt) ≈ 1.5 px. A strict ±1 px equality check here
            // misses that overshoot frame and the contact never registers,
            // making slide / wall-jump impossible. Detect contact by partial
            // overlap on the approach side instead, gated to the wall's own
            // width so the player has to actually be touching the surface.
            if wall.direction > 0 {
                if playerHitbox.maxX >= wallHB.minX - 1
                    && playerHitbox.minX < wallHB.minX {
                    return .right
                }
            } else {
                if playerHitbox.minX <= wallHB.maxX + 1
                    && playerHitbox.maxX > wallHB.maxX {
                    return .left
                }
            }
        }
        return nil
    }

    /// Mirrors Godot `Event.emit_signal("sigma_desperation", direction)`. Each
    /// wall whose `direction` matches `direction` enters its 1.65 s blink +
    /// destruction sequence. Other walls keep their collider for the rest of
    /// the fight.
    func onSigmaDesperation(direction: Int) {
        for wall in sigmaWalls { wall.onDesperation(attackDirection: direction) }
    }

    // MARK: - Defeat / Victory / Game Over

    /// Called once on the `.fighting → .defeat` edge. Godot pauses the scene
    /// via `GameManager.pause("PlayerDeath")` on Player death entry; we mirror
    /// the behavioural effect (stop the boss + clear hazards) without tying a
    /// global pause to this scene, so the player-side death animation still
    /// ticks.
    private func enterDefeat() {
        phase = .defeat
        phaseTimer = 0
        ensureFadeOverlay()
        // Kill any in-progress attack so its hitbox can't tick or damage on
        // the final frame before the scene transitions. Leave projectiles
        // alive so showpieces like the OverdriveAttack beam keep rendering
        // through the death sequence — Godot's GameManager.pause freezes
        // them in place, and despawning here made the 2.4s laser vanish the
        // instant it touched the player.
        boss.interruptAttack()
    }

    /// Called once on the `.fighting → .victory` edge. Deactivates the boss AI
    /// by replacing it with a fresh (un-activated) instance so lingering state
    /// (cooldown, cursor, order) doesn't drive any attacks after the kill, and
    /// kicks off the BossDeath cutscene visuals (boss death pose + player
    /// victory pose). The 13 s explosion + fade cadence is driven by
    /// `tickVictorySequence`.
    private func enterVictory() {
        phase = .victory
        phaseTimer = 0
        victoryBurstAccumulator = 0
        victoryFlashFired = false
        victoryBossHidden = false
        bossAI = BossAI(context: SceneAttackContext(scene: self))
        for p in projectiles where p.owner == .boss { p.isAlive = false }
        boss.enterDeathSequence()
        player.enterVictoryPose()
        ensureFadeOverlay()
    }

    /// 3-stage cadence ported from Godot BossDeath.gd:
    ///   t = 0 .. 1.0  — freeze (death anim plays once, no bursts)
    ///   t = 1.0 .. 11.0 — 10 s explosion barrage at 0.45 s cadence
    ///   t = 11.0 .. 11.45 — full-screen white flash, then fade in begins
    ///   t = 11.45 .. 14.0 — boss sprite hidden, fade overlay → opaque
    /// Past 14 s the scene holds on the opaque fade indefinitely (Godot would
    /// hand off to weapon-get / stage-select; v1 has no such follow-up).
    private func tickVictorySequence(_ dt: TimeInterval) {
        if phaseTimer < Self.victoryFreeze { return }

        if phaseTimer < Self.victoryExplosionEnd {
            victoryBurstAccumulator += dt
            while victoryBurstAccumulator >= Self.victoryBurstInterval {
                victoryBurstAccumulator -= Self.victoryBurstInterval
                spawnVictoryBurst()
            }
            return
        }

        if !victoryFlashFired {
            victoryFlashFired = true
            let flash = BossEffects.bossDeathScreenFlash(
                stageSize: CGSize(width: stage.width, height: stage.height)
            )
            addChild(flash)
        }

        if phaseTimer >= Self.victoryFlashEnd && !victoryBossHidden {
            victoryBossHidden = true
            boss.setVisualHidden(true)
        }

        let fadeStart = Self.victoryFlashEnd
        let fadeWindow = Self.victoryFadeEnd - fadeStart
        let elapsed = phaseTimer - fadeStart
        if elapsed > 0 {
            fadeOverlay?.alpha = min(1.0, CGFloat(elapsed / fadeWindow))
        }
    }

    /// Spawn one boss-death burst at a random offset within the boss's body
    /// rect. Mirrors the spread Godot's `explosions` particle process gives
    /// when its emission shape covers the boss sprite.
    private func spawnVictoryBurst() {
        let bx = boss.position.x + CGFloat.random(in: -Boss.bodySize.width / 2 ... Boss.bodySize.width / 2)
        let by = boss.position.y + CGFloat.random(in: 8 ... Boss.bodySize.height - 4)
        addChild(BossEffects.bossDeathBurst(at: CGPoint(x: bx, y: by)))
    }

    /// Lazy-create the full-screen black fade overlay. zPosition sits above the
    /// HUD (`100`) and FPS label (`200`) so the fade covers everything on the
    /// arena, matching Godot's `fade_out` shader which runs as a full-viewport
    /// ColorRect.
    private func ensureFadeOverlay() {
        if fadeOverlay != nil { return }
        let overlay = SKSpriteNode(
            color: SKColor.black,
            size: CGSize(width: stage.width, height: stage.height)
        )
        overlay.anchorPoint = .zero
        overlay.position = .zero
        overlay.alpha = 0
        overlay.zPosition = 300
        addChild(overlay)
        fadeOverlay = overlay
    }

    /// Mirrors Godot PlayerDeath._Update fade ramp: alpha starts climbing once
    /// the death sequence reaches 1.5 s and is fully opaque by ~2.0 s
    /// (`alpha += delta * 2` in Godot). The scene's `phaseTimer` aligns with
    /// the player's `deathSequenceElapsed` since both reset on the same edge.
    private func updateDefeatFade() {
        ensureFadeOverlay()
        let elapsed = phaseTimer - 1.5
        let alpha: CGFloat = elapsed <= 0 ? 0 : min(1.0, CGFloat(elapsed) * 2.0)
        fadeOverlay?.alpha = alpha
    }

    /// Godot `finished_fade_out` branching. Lives > 0 → restart_level; lives
    /// == 0 → emit `game_over` and change scene. The E2E port collapses the
    /// latter into a `.gameOver` phase that shows a label for 3 s then hard
    /// resets everything, so there's no dead-end state in the battle scene.
    private func onPlayerDeath() {
        if playerLives > 0 {
            playerLives -= 1
            resetBattle()
        } else {
            phase = .gameOver
            phaseTimer = 0
            showGameOverLabel()
        }
    }

    private func showGameOverLabel() {
        ensureFadeOverlay()
        fadeOverlay?.alpha = 1.0
        let label = SKLabelNode(fontNamed: "Menlo")
        label.text = "GAME OVER"
        label.fontSize = 36
        label.fontColor = SKColor.white
        label.position = CGPoint(x: stage.width / 2, y: stage.height / 2)
        label.zPosition = 310
        addChild(label)
        gameOverLabel = label
    }

    private func hideGameOverLabel() {
        gameOverLabel?.removeFromParent()
        gameOverLabel = nil
    }

    /// Godot `restart_level` equivalent — respawn the player, reset the boss,
    /// discard every projectile, and re-enter the intro phase. The `BossAI`
    /// is recreated so its seed-driven attack order restarts from scratch.
    private func resetBattle() {
        player.respawn(at: stage.playerSpawn)
        boss.interruptAttack()
        boss.heal(boss.maxHealth)
        boss.position = stage.bossSpawn
        boss.velocity = .zero
        boss.gravityScale = 1
        boss.onFloor = true
        if boss.facing != .left { boss.face(.left) }
        for p in projectiles { p.removeFromParent() }
        projectiles.removeAll()
        for wall in sigmaWalls { wall.reset() }
        bossAI = BossAI(context: SceneAttackContext(scene: self))
        fadeOverlay?.alpha = 0
        hideGameOverLabel()
        phaseTimer = 0
        // Reset the intro state — re-enter the 9-stage scripted cutscene so a
        // retry replays exactly the same intro a fresh load sees.
        sigmaIntro.reset()
        sigmaIntro.begin()
        bossHealthBar.alpha = 0
        bossHealthBar.startFillAnimation(to: 0, duration: 0)
        screenShakeTimer = 0
        backdrop.position = .zero
        boss.setVisualHidden(false)
        victoryBurstAccumulator = 0
        victoryFlashFired = false
        victoryBossHidden = false
        phase = .intro
    }

    /// Godot `game_over → go_to_stage_select` eventually returns to a fresh
    /// battle with full lives. The E2E port skips the stage-select detour and
    /// just restores starting lives before replaying the battle.
    private func resetGame() {
        playerLives = BossBattleScene.startingLives
        resetBattle()
    }

    // MARK: - Intro signal hooks
    // Godot emits Event signals from Intro.gd (`play_boss_music`, `sigma_walls`,
    // `set_boss_bar`, `boss_health_appear`, `intro_concluded`). Our port has no
    // audio or signal bus, so SigmaIntro calls these methods directly in the
    // same order to preserve ordering semantics.

    /// Intro stage 3: `Event.emit_signal("play_boss_music")`. We have no audio
    /// pipeline yet; kept as a seam so the hook is observable for tests.
    func onBossMusicStart() {
        // No-op — audio not wired.
    }

    /// Intro stage 4 throne destruction — flash overlay at the boss's sprite
    /// center. Godot spawns the flash as a child of `Intro` with its own
    /// `flash.gd` properties (white→violet, 0.2s).
    func spawnIntroFlash() {
        let center = CGPoint(
            x: boss.position.x,
            y: boss.position.y + Boss.bodySize.height / 2
        )
        addChild(BossEffects.introFlash(at: center))
    }

    /// Intro stage 4 — scatter debris where the throne used to stand. Godot
    /// does `throne.queue_free()` + `throne_explosion.play()` + particle emit.
    func spawnThroneExplosion() {
        let base = CGPoint(x: boss.position.x, y: boss.position.y + 8)
        addChild(BossEffects.throneExplosion(at: base))
    }

    /// Intro stage 4 — arm the screen-shake timer. Mirrors Godot's default
    /// `screenshake(value := 2.0)` falloff with a brief, low-amplitude jitter.
    func startScreenShake(duration: TimeInterval, amplitude: CGFloat) {
        screenShakeTimer = max(screenShakeTimer, duration)
        screenShakeAmplitude = max(screenShakeAmplitude, amplitude)
    }

    /// Intro stage 6: `Event.emit_signal("boss_health_appear", character)`.
    /// HUD.gd fades the boss bar in and kicks off the `fill_boss_hp` ramp.
    func onBossHealthAppear() {
        bossHealthBar.alpha = 1
        bossHealthBar.startFillAnimation(to: boss.maxHealth)
    }

    /// Intro stage 8 end: `character.emit_signal("intro_concluded")`, which in
    /// Godot triggers `BossAI.activate_ai()`. We mirror that ordering exactly.
    func onIntroConcluded() {
        phase = .fighting
        bossAI.activate()
    }

    // MARK: - Screen shake

    private func tickScreenShake(_ dt: TimeInterval) {
        guard screenShakeTimer > 0 else {
            if backdrop.position != .zero { backdrop.position = .zero }
            return
        }
        screenShakeTimer = max(0, screenShakeTimer - dt)
        if screenShakeTimer > 0 {
            backdrop.position = CGPoint(
                x: CGFloat.random(in: -screenShakeAmplitude...screenShakeAmplitude),
                y: CGFloat.random(in: -screenShakeAmplitude...screenShakeAmplitude)
            )
        } else {
            backdrop.position = .zero
            screenShakeAmplitude = 0
        }
    }

    // MARK: - Debug markers
    // Visual crosshairs the harness can drop at arbitrary world positions for
    // ad-hoc debugging (e.g. verifying the cannon-mouth coordinate maps onto
    // Sigma's actual cannon arm pixels). Each marker is a transparent SKNode
    // host with a horizontal + vertical 1×N rect child so the centre lines
    // sit exactly at the requested point regardless of zoom.

    private var debugMarkers: [SKNode] = []

    func spawnDebugMarker(at point: CGPoint, color: SKColor, ttl: TimeInterval) {
        let marker = SKNode()
        marker.position = point
        marker.zPosition = 999
        let span: CGFloat = 16
        let thickness: CGFloat = 1
        let h = SKSpriteNode(color: color, size: CGSize(width: span, height: thickness))
        h.position = .zero
        marker.addChild(h)
        let v = SKSpriteNode(color: color, size: CGSize(width: thickness, height: span))
        v.position = .zero
        marker.addChild(v)
        let dot = SKSpriteNode(color: color, size: CGSize(width: 2, height: 2))
        dot.position = .zero
        marker.addChild(dot)
        addChild(marker)
        debugMarkers.append(marker)
        if ttl > 0 {
            marker.run(SKAction.sequence([
                SKAction.wait(forDuration: ttl),
                SKAction.removeFromParent()
            ]))
        }
    }

    func clearDebugMarkers() {
        for m in debugMarkers { m.removeFromParent() }
        debugMarkers.removeAll()
    }

    /// Public seam over the private `resetBattle` so the harness can restart a
    /// battle without reloading the page. Mirrors the path the dead-state
    /// transition uses.
    func debugResetBattle() {
        resetBattle()
    }

    // MARK: - Debug projectile snapshot

    struct ProjectileSnapshot: Sendable {
        let kind: String
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        let vx: Double
        let vy: Double
        let alive: Bool
        let owner: String
    }

    func projectileSnapshots() -> [ProjectileSnapshot] {
        projectiles.map { p in
            let kind: String
            switch p.kind {
            case .lemon:         kind = "lemon"
            case .mediumBuster:  kind = "mediumBuster"
            case .chargedBuster: kind = "chargedBuster"
            case .sigmaBall:     kind = "sigmaBall"
            case .sigmaLance:    kind = "sigmaLance"
            case .sigmaLaser:    kind = "sigmaLaser"
            }
            let owner: String
            switch p.owner {
            case .player: owner = "player"
            case .boss:   owner = "boss"
            }
            return ProjectileSnapshot(
                kind: kind,
                x: Double(p.position.x),
                y: Double(p.position.y),
                w: Double(p.size.width),
                h: Double(p.size.height),
                vx: Double(p.velocity.dx),
                vy: Double(p.velocity.dy),
                alive: p.isAlive,
                owner: owner
            )
        }
    }
}

// MARK: - SceneAttackContext
// Bridge between BossAI / Attacks and the scene without leaking SKScene into the protocol.

@MainActor
private final class SceneAttackContext: AttackContext {
    weak var scene: BossBattleScene?

    init(scene: BossBattleScene) {
        self.scene = scene
    }

    var boss: Boss { scene!.boss }
    var player: Player { scene!.player }
    var stageWidth: CGFloat { scene!.stageWidth }
    var floorY: CGFloat { scene!.stage.floorY }
    var arenaWallLeft: CGFloat { 16 }
    var arenaWallRight: CGFloat { scene!.stage.width - 16 }

    func spawnProjectile(_ projectile: Projectile) {
        scene?.spawnProjectile(projectile)
    }

    func spawnEffect(_ node: SKNode) {
        scene?.addChild(node)
    }

    func emitDesperation(direction: Int) {
        scene?.onSigmaDesperation(direction: direction)
    }

    func screenshake(amplitude: CGFloat, duration: TimeInterval) {
        scene?.startScreenShake(duration: duration, amplitude: amplitude)
    }
}
