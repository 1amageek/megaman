import Foundation
import OpenSpriteKit

// MARK: - BossPreviewScene
// Standalone Sigma viewer that backs `/assets/boss-preview.html`. Mirrors the
// PlayerPreviewScene pattern: build the same `Boss` + ghost `Player` instances
// the battle scene uses, but skip the BossAI scheduler / SigmaIntro / collision
// resolver / projectile-vs-player logic. The page drives which `BossAI.AttackKind`
// is on screen via `__megaman_boss_preview.setActiveAttack(...)`; the scene
// instantiates the matching `Attack` against a private `PreviewAttackContext`
// and forwards `dt` so the state machine progresses normally.
//
// Why a separate scene (not a flag on BossBattleScene): the battle scene's
// update loop is gated on `phase == .fighting`, threads through SigmaIntro
// + GameOverFade, and keeps a `permanentChildIDs` allow-list driven by the
// intro's ARM / DISARM cycle. Reusing it would require carving out a fourth
// `phase` and short-circuiting half the update branches — separate scene is
// less code and makes the preview's contract obvious.
@MainActor
final class BossPreviewScene: SKScene {
    let boss: Boss
    let player: Player
    private let stage: Stage = .bossArena
    private var lastUpdateTime: TimeInterval?
    private var projectiles: [Projectile] = []
    private var projectileAtlases: [ProjectileKind: SpriteAtlas] = [:]
    private var context: PreviewAttackContext!

    init(forPreview: Void = ()) {
        self.boss = Boss()
        self.player = Player()
        super.init(size: CGSize(width: stage.width, height: stage.height))
        self.anchorPoint = .zero
        self.backgroundColor = SKColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1.0)
        self.context = PreviewAttackContext(scene: self)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Atlas binding

    func attachBossAtlas(_ atlas: SpriteAtlas) {
        boss.attachAtlas(atlas)
    }

    func attachPlayerAtlas(_ atlas: SpriteAtlas) {
        player.attachAtlas(atlas)
    }

    func attachProjectileAtlas(_ atlas: SpriteAtlas, for kind: ProjectileKind) {
        projectileAtlases[kind] = atlas
    }

    // MARK: - Lifecycle

    nonisolated override func didMove(to view: SKView) {
        super.didMove(to: view)
        withMainActorCallbackOwner(self) { scene in
            scene.buildScene()
        }
    }

    private func buildScene() {
        // Sigma Palace floor band (primitive — no backdrop atlas in preview).
        let floor = SKSpriteNode(
            color: SKColor(red: 0.18, green: 0.20, blue: 0.28, alpha: 1.0),
            size: CGSize(width: stage.width, height: stage.floorY)
        )
        floor.anchorPoint = .zero
        floor.position = .zero
        floor.zPosition = -10
        addChild(floor)

        // Sigma Wall pillars at the same x positions the battle scene places
        // them — needed because LanceThrow's raycast terminates at these
        // x-coordinates (see AttackContext.arenaWallLeft / arenaWallRight).
        let leftPillar = SKSpriteNode(
            color: SKColor(red: 0.42, green: 0.30, blue: 0.55, alpha: 1.0),
            size: CGSize(width: 16, height: stage.height - stage.floorY)
        )
        leftPillar.anchorPoint = CGPoint(x: 0.5, y: 0)
        leftPillar.position = CGPoint(x: context.arenaWallLeft, y: stage.floorY)
        leftPillar.zPosition = -8
        addChild(leftPillar)

        let rightPillar = SKSpriteNode(
            color: SKColor(red: 0.42, green: 0.30, blue: 0.55, alpha: 1.0),
            size: CGSize(width: 16, height: stage.height - stage.floorY)
        )
        rightPillar.anchorPoint = CGPoint(x: 0.5, y: 0)
        rightPillar.position = CGPoint(x: context.arenaWallRight, y: stage.floorY)
        rightPillar.zPosition = -8
        addChild(rightPillar)

        // Boss + ghost Player. Spawn positions match the battle scene so
        // attack ranges + lance trajectories visually map to gameplay.
        boss.position = stage.bossSpawn
        boss.face(.left)
        addChild(boss)

        player.position = stage.playerSpawn
        // Preview-mode Player: short-circuits input / physics into tickPreview,
        // and `Player.world` stays nil so the few `world?.…` call sites in
        // shoot / wallContact gracefully no-op (see PlayerWorld docstring).
        player.previewMode = true
        player.preview(.idle)
        addChild(player)
    }

    // MARK: - Public API (driven by __megaman_boss_preview)

    /// Phase-1 attack list is the full BossAI roster — not just LanceThrow +
    /// GroundCombo — because every kind already runs against the same
    /// AttackContext interface, so allowing the preview to instantiate them
    /// costs nothing and keeps the page UI consistent with BossAI.forceAttack.
    func setActiveAttack(_ kind: BossAI.AttackKind) {
        clearAttackArtifacts()
        boss.faceToward(x: player.position.x)
        let attack: Attack
        switch kind {
        case .groundCombo: attack = GroundCombo(context: context)
        case .jumpCombo:   attack = JumpCombo(context: context)
        case .lanceThrow:  attack = LanceThrow(context: context)
        case .airCombo:    attack = AirCombo(context: context)
        }
        attack.start()
        boss.activeAttack = attack
    }

    /// Stop the active attack and clear every projectile / effect node it
    /// spawned. Intended for the page's "Stop" button + before each
    /// setActiveAttack so attacks don't compound on top of stale visuals.
    func stopActiveAttack() {
        boss.interruptAttack()
        clearAttackArtifacts()
        boss.playAnimation("idle", repeating: true)
    }

    /// Move the ghost player horizontally. Y-coordinate is pinned to floorY
    /// because the preview has no jump input and the ghost is always grounded.
    func setPlayerX(_ x: CGFloat) {
        let clamped = max(stage.wallWidth + 8,
                          min(stage.width - stage.wallWidth - 8, x))
        player.position = CGPoint(x: clamped, y: stage.floorY)
    }

    /// Read the active attack's current stage label. Returns nil when no
    /// AttackPreviewable attack is running. Polled by the page so the timeline
    /// row can highlight the live stage.
    var activeStageLabel: String? {
        guard let attack = boss.activeAttack as? any AttackPreviewable else {
            return nil
        }
        let names = type(of: attack).previewStageNames
        let idx = attack.previewStageIndex
        guard idx >= 0, idx < names.count else { return nil }
        return names[idx]
    }

    /// Static stage list for the active attack, used by the page to render
    /// the timeline row when an AttackPreviewable attack starts.
    var activeStageNames: [String]? {
        guard let attack = boss.activeAttack as? any AttackPreviewable else {
            return nil
        }
        return type(of: attack).previewStageNames
    }

    func resetTimeline() {
        lastUpdateTime = nil
    }

    // MARK: - Tick

    nonisolated override func update(_ currentTime: TimeInterval) {
        withMainActorCallbackOwner(self) { scene in
            scene.updateOnMainActor(currentTime)
        }
    }

    private func updateOnMainActor(_ currentTime: TimeInterval) {
        let dt: TimeInterval
        if let last = lastUpdateTime {
            dt = min(1.0 / 30.0, currentTime - last)
        } else {
            dt = 1.0 / 60.0
        }
        lastUpdateTime = currentTime
        if isPaused { return }

        boss.tick(dt, stageWidth: stage.width, floorY: stage.floorY)
        player.tick(dt,
                    input: InputManager.shared,
                    stageWidth: stage.width,
                    floorY: stage.floorY)
        tickProjectiles(dt)
    }

    // MARK: - Projectile lifecycle (mirrors BossBattleScene.spawnProjectile/tickProjectiles)

    fileprivate func spawnProjectile(_ projectile: Projectile) {
        projectiles.append(projectile)
        addChild(projectile)
        if let atlas = projectileAtlases[projectile.kind] {
            projectile.attachAtlas(
                atlas,
                tag: defaultAnimationTag(for: projectile.kind),
                visualSize: defaultVisualSize(for: projectile.kind)
            )
        }
        if projectile.kind == .sigmaLance {
            BossEffects.attachLanceOverlays(to: projectile)
        }
    }

    private func tickProjectiles(_ dt: TimeInterval) {
        for projectile in projectiles where projectile.isAlive {
            projectile.tick(dt, stageWidth: stage.width, floorY: stage.floorY)
        }
        projectiles.removeAll { p in
            if !p.isAlive { p.removeFromParent(); return true }
            return false
        }
    }

    private func clearAttackArtifacts() {
        for p in projectiles { p.removeFromParent() }
        projectiles.removeAll()
        // Effect nodes (LanceThrow's aim laser, OverdriveAttack's charge ring,
        // any spawnEffect children) are added directly to the scene; sweep
        // every non-permanent child so the next attack starts visually clean.
        for node in children {
            if node === boss || node === player { continue }
            if node.zPosition <= -8 { continue } // floor + pillars
            node.removeAllActions()
            node.removeFromParent()
        }
    }

    private func defaultAnimationTag(for kind: ProjectileKind) -> String {
        switch kind {
        case .lemon:         return "Tag"
        case .mediumBuster:  return "loop"
        case .chargedBuster: return "Tag"
        case .sigmaBall:     return "evilfire_loop"
        case .sigmaLance:    return "loop"
        case .sigmaLaser:    return "cannon_loop"
        }
    }

    private func defaultVisualSize(for kind: ProjectileKind) -> CGSize {
        switch kind {
        case .lemon:         return CGSize(width: 32, height: 32)
        case .mediumBuster:  return CGSize(width: 48, height: 48)
        case .chargedBuster: return CGSize(width: 64, height: 64)
        case .sigmaBall:     return CGSize(width: 80, height: 80)
        case .sigmaLance:    return CGSize(width: 32, height: 160)
        case .sigmaLaser:    return CGSize(width: 398, height: 208)
        }
    }
}

// MARK: - PreviewAttackContext
// Mirrors BossBattleScene's SceneAttackContext: thin AttackContext shim that
// hands attacks the boss / player references and the arena bounds without
// leaking SKScene into the protocol. emitDesperation + screenshake are
// no-ops here — the preview has no SigmaWall destruction listener and no
// camera shake helper.
@MainActor
private final class PreviewAttackContext: AttackContext {
    weak var scene: BossPreviewScene?

    init(scene: BossPreviewScene) {
        self.scene = scene
    }

    var boss: Boss { scene!.boss }
    var player: Player { scene!.player }
    var stageWidth: CGFloat { CGFloat(GameConfig.gameWidth) }
    var floorY: CGFloat { GameConfig.floorY }
    var arenaWallLeft: CGFloat { 16 }
    var arenaWallRight: CGFloat { stageWidth - 16 }

    func spawnProjectile(_ projectile: Projectile) {
        scene?.spawnProjectile(projectile)
    }

    func spawnEffect(_ node: SKNode) {
        scene?.addChild(node)
    }

    func emitDesperation(direction: Int) {
        // No SigmaWall in the preview — nothing to wake.
    }

    func screenshake(amplitude: CGFloat, duration: TimeInterval) {
        // No camera shake in the preview; the page can read attack state
        // without the visual interfering.
    }
}
