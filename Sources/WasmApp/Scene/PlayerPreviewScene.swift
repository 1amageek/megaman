import Foundation
import OpenSpriteKit

// MARK: - PlayerPreviewScene
// Standalone Player viewer that backs `/assets/player-preview.html`. Renders
// the same `Player` node + `PlayerEffects` particles the boss arena uses, but
// without `BossBattleScene`'s combat graph (no boss, no AI, no projectiles,
// no intro). The preview-mode Player short-circuits input + physics in
// `Player.tickPreview(_:)`, so the scene only has to forward `dt` and let the
// `Player.preview(_:)` API drive which Action is on screen.
@MainActor
final class PlayerPreviewScene: SKScene {
    let player: Player
    private var lastUpdateTime: TimeInterval?
    // Visual stand-in for the wall referenced by .slide / .wallJump. Sits
    // flush with the body's outer edge so the user can see which side the
    // sprite + particles are assuming the wall is on (Wallslide.gd:14 places
    // the player AWAY from the wall, Walljump.gd:25 places them TOWARD it).
    private var wallNode: SKSpriteNode?

    // Distinct init signature (takes no args) so it doesn't collide with
    // SKScene's inherited `init()`. We construct the scene at the native
    // game resolution unconditionally; CSS scales the canvas.
    init(forPreview: Void = ()) {
        self.player = Player()
        super.init(size: CGSize(width: GameConfig.gameWidth, height: GameConfig.gameHeight))
        self.anchorPoint = .zero
        self.backgroundColor = SKColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1.0)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Bind the X atlas. Called from main.swift after `SpriteLoader.load` for
    /// the `player/x` atlas finishes — preview mode loads only this atlas
    /// (boss / projectile / background atlases are skipped).
    func attachPlayerAtlas(_ atlas: SpriteAtlas) {
        player.attachAtlas(atlas)
    }

    /// Bind the charge overlay atlas. Useful so the preview can demonstrate
    /// the charging particle ring around X — same wiring path as the boss
    /// scene uses.
    func attachChargeAtlas(_ atlas: SpriteAtlas, for level: Int) {
        player.attachChargeAtlas(atlas, for: level)
    }

    nonisolated override func didMove(to view: SKView) {
        super.didMove(to: view)
        withMainActorCallbackOwner(self) { scene in
            scene.buildScene()
        }
    }

    private func buildScene() {
        // Subtle floor band at the same Y the boss arena uses so the user can
        // visually align the character's feet with the in-game floor.
        let floor = SKSpriteNode(
            color: SKColor(red: 0.18, green: 0.20, blue: 0.28, alpha: 1.0),
            size: CGSize(width: CGFloat(GameConfig.gameWidth), height: GameConfig.floorY)
        )
        floor.anchorPoint = .zero
        floor.position = CGPoint(x: 0, y: 0)
        floor.zPosition = -10
        addChild(floor)

        // Center the player horizontally; sit on the floor.
        player.position = CGPoint(x: CGFloat(GameConfig.gameWidth) / 2,
                                  y: GameConfig.floorY)
        player.previewMode = true
        addChild(player)

        // Wall placeholder — vertical band the player can be wall-sliding /
        // wall-jumping against. Hidden until syncWall() positions it for an
        // action that needs one.
        let wall = SKSpriteNode(
            color: SKColor(red: 0.55, green: 0.45, blue: 0.30, alpha: 1.0),
            size: CGSize(width: 16, height: GameConfig.floorY * 1.6)
        )
        wall.anchorPoint = CGPoint(x: 0.5, y: 0)
        wall.zPosition = -8
        wall.isHidden = true
        addChild(wall)
        wallNode = wall

        // Default to idle — the page bootstrap can switch this via
        // `__megaman_preview.setAction(...)` once WASM is up.
        player.preview(.idle)
        syncWall()
    }

    /// Reposition + show/hide the wall placeholder so it lines up with the
    /// side `Player.preview(_:)` baked into `wallContact`. Idempotent —
    /// safe to call from setAction and setFacing.
    func syncWall() {
        guard let wallNode else { return }
        // Mirror Player.preview(_:)'s wallContact rule so the visual matches
        // exactly what the dust dispatcher reads:
        //   .slide    → wall = facing.opposite (player faces AWAY)
        //   .wallJump → wall = facing           (player faces TOWARD)
        let wallSide: Facing?
        switch player.previewAction {
        case .some(.slide):    wallSide = player.facing.opposite
        case .some(.wallJump): wallSide = player.facing
        default:               wallSide = nil
        }
        guard let side = wallSide else {
            wallNode.isHidden = true
            return
        }
        // Player body is 14 px wide, so the outer edge sits at ±7 from the
        // anchor; place the wall flush with the body edge.
        let offsetX: CGFloat = 7 + 8  // body half-width + wall half-width
        wallNode.position = CGPoint(x: player.position.x + side.sign * offsetX,
                                    y: 0)
        wallNode.isHidden = false
    }

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
        player.tick(dt, input: InputManager.shared,
                    stageWidth: CGFloat(GameConfig.gameWidth),
                    floorY: GameConfig.floorY)
    }

    func resetTimeline() {
        lastUpdateTime = nil
    }
}
