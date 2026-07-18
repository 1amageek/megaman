import Foundation
import OpenSpriteKit

// MARK: - Stage
// Boss arena bounds. Minimal for v1 — flat floor, fixed width.

struct Stage {
    let width: CGFloat
    let height: CGFloat
    let floorY: CGFloat
    let wallWidth: CGFloat = 8

    static let bossArena = Stage(
        width: CGFloat(GameConfig.gameWidth),
        height: CGFloat(GameConfig.gameHeight),
        floorY: GameConfig.floorY
    )

    var playerSpawn: CGPoint {
        // Divergence from the Godot reference (which places the player at
        // arena-local x=148 via PlayerMover.gd's boss.x-100 rule): in the
        // Godot camera setup the Sigma sprite is offset by the level tilemap
        // so the lance doesn't appear on top of the player. Our 398x192
        // atlas frame is rendered centred on the Boss node, which pulls the
        // lance visual ~49 arena px left of Sigma's body — with the Godot
        // 100 px gap that put the lance tip right in the player's face.
        // Push the player toward the left arena edge to open the visual gap.
        CGPoint(x: width * 0.20, y: floorY)
    }

    var bossSpawn: CGPoint {
        // Divergence from the Godot reference (arena-local x=248 = 62.3%):
        // pushed right to 80% so Sigma's 398-wide frame still fits inside
        // the arena while opening ~240 arena px between player and lance tip.
        // See playerSpawn comment for why the reference gap felt tight in
        // our renderer.
        CGPoint(x: width * 0.80, y: floorY)
    }
}

// MARK: - StageBackdrop
// Visual backdrop. The primitive coloured rects are kept as a fallback for
// the brief window between scene init and async sprite load — once
// `attachAtlases(bg:clouds:)` resolves we swap in the actual Aseprite art
// (`final_fight.png` + `far_clouds.png`).

@MainActor
final class StageBackdrop: SKNode {
    private let stage: Stage
    private var primitiveLayers: [SKNode] = []
    private var bgSprite: SKSpriteNode?
    private var cloudSprites: [SKSpriteNode] = []
    private var cloudScrollOffset: CGFloat = 0
    private static let cloudScrollSpeed: CGFloat = 6  // px/s

    init(stage: Stage) {
        self.stage = stage
        super.init()
        installPrimitiveBackdrop()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replace the placeholder rectangles with sprite-atlas artwork. Passing
    /// nil for either layer leaves that layer in its primitive form.
    func attachAtlases(bg: SpriteAtlas?, clouds: SpriteAtlas?) {
        if let texture = bg?.animations.first?.value.textures.first {
            removePrimitiveBackdrop()
            installBackgroundSprite(texture: texture)
        }
        if let texture = clouds?.animations.first?.value.textures.first {
            installCloudParallax(texture: texture)
        }
    }

    /// Drift the cloud parallax band sideways to keep the backdrop alive
    /// during a stationary boss arena (no camera pans in the v1 scope).
    func tick(_ dt: TimeInterval) {
        guard !cloudSprites.isEmpty,
              let texW = cloudSprites.first?.size.width,
              texW > 0 else { return }
        cloudScrollOffset = cloudScrollOffset - StageBackdrop.cloudScrollSpeed * CGFloat(dt)
        // Keep the offset in [-texW, 0] so each tile stays in-frame.
        if cloudScrollOffset <= -texW { cloudScrollOffset += texW }
        for (i, sprite) in cloudSprites.enumerated() {
            sprite.position = CGPoint(
                x: cloudScrollOffset + CGFloat(i) * texW,
                y: sprite.position.y
            )
        }
    }

    private func installPrimitiveBackdrop() {
        let sky = SKSpriteNode(
            color: SKColor(red: 0.09, green: 0.08, blue: 0.16, alpha: 1.0),
            size: CGSize(width: stage.width, height: stage.height)
        )
        sky.anchorPoint = CGPoint(x: 0, y: 0)
        sky.position = .zero
        sky.zPosition = 0
        addChild(sky)
        primitiveLayers.append(sky)

        let band = SKSpriteNode(
            color: SKColor(red: 0.15, green: 0.12, blue: 0.22, alpha: 1.0),
            size: CGSize(width: stage.width, height: 60)
        )
        band.anchorPoint = CGPoint(x: 0, y: 0)
        band.position = CGPoint(x: 0, y: stage.floorY + 40)
        band.zPosition = 1
        addChild(band)
        primitiveLayers.append(band)

        let floor = SKSpriteNode(
            color: SKColor(red: 0.3, green: 0.3, blue: 0.38, alpha: 1.0),
            size: CGSize(width: stage.width, height: stage.floorY)
        )
        floor.anchorPoint = CGPoint(x: 0, y: 0)
        floor.position = .zero
        floor.zPosition = 2
        addChild(floor)
        primitiveLayers.append(floor)

        let edge = SKSpriteNode(
            color: SKColor(red: 0.55, green: 0.55, blue: 0.65, alpha: 1.0),
            size: CGSize(width: stage.width, height: 2)
        )
        edge.anchorPoint = CGPoint(x: 0, y: 0)
        edge.position = CGPoint(x: 0, y: stage.floorY)
        edge.zPosition = 3
        addChild(edge)
        primitiveLayers.append(edge)

        let wallHeight = stage.height - stage.floorY
        let wallColor = SKColor(red: 0.18, green: 0.21, blue: 0.30, alpha: 1.0)
        let leftWall = SKSpriteNode(
            color: wallColor,
            size: CGSize(width: stage.wallWidth, height: wallHeight)
        )
        leftWall.anchorPoint = CGPoint(x: 0, y: 0)
        leftWall.position = CGPoint(x: 0, y: stage.floorY)
        leftWall.zPosition = 4
        addChild(leftWall)
        primitiveLayers.append(leftWall)

        let rightWall = SKSpriteNode(
            color: wallColor,
            size: CGSize(width: stage.wallWidth, height: wallHeight)
        )
        rightWall.anchorPoint = CGPoint(x: 1, y: 0)
        rightWall.position = CGPoint(x: stage.width, y: stage.floorY)
        rightWall.zPosition = 4
        addChild(rightWall)
        primitiveLayers.append(rightWall)
    }

    private func removePrimitiveBackdrop() {
        for node in primitiveLayers { node.removeFromParent() }
        primitiveLayers.removeAll()
    }

    private func installBackgroundSprite(texture: SKTexture) {
        let sprite = SKSpriteNode(texture: texture)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.position = CGPoint(x: stage.width / 2, y: 0)
        // Prefer the source PNG resolution but stretch to cover the arena
        // when widths differ (final_fight.png is 400, arena is 398).
        sprite.size = CGSize(width: stage.width, height: stage.height)
        sprite.zPosition = 0
        addChild(sprite)
        bgSprite = sprite
    }

    private func installCloudParallax(texture: SKTexture) {
        // Tile horizontally so the band fully covers the arena width. The
        // cloud PNG is small (64 px), so we need ⌈width / texW⌉ + 1 copies
        // for the scroll offset to hide the seam.
        for sprite in cloudSprites { sprite.removeFromParent() }
        cloudSprites.removeAll()

        let texW = texture.size().width
        let texH = texture.size().height
        guard texW > 0, texH > 0 else { return }
        let copies = Int((stage.width / texW).rounded(.up)) + 1
        // Cloud band sits roughly mid-height between the floor and the top.
        let bandY = stage.floorY + (stage.height - stage.floorY) * 0.55
        for i in 0..<copies {
            let sprite = SKSpriteNode(texture: texture)
            sprite.anchorPoint = CGPoint(x: 0, y: 0.5)
            sprite.position = CGPoint(x: CGFloat(i) * texW, y: bandY)
            sprite.size = CGSize(width: texW, height: texH)
            sprite.zPosition = 0.5
            sprite.alpha = 0.6
            addChild(sprite)
            cloudSprites.append(sprite)
        }
    }
}
