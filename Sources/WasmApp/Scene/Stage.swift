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
// Visual backdrop — solid sky + dark pillar + floor strip. Placeholder for tilemap.

@MainActor
final class StageBackdrop: SKNode {
    init(stage: Stage) {
        super.init()

        let sky = SKSpriteNode(
            color: SKColor(red: 0.09, green: 0.08, blue: 0.16, alpha: 1.0),
            size: CGSize(width: stage.width, height: stage.height)
        )
        sky.anchorPoint = CGPoint(x: 0, y: 0)
        sky.position = .zero
        sky.zPosition = 0
        addChild(sky)

        // Back wall band
        let band = SKSpriteNode(
            color: SKColor(red: 0.15, green: 0.12, blue: 0.22, alpha: 1.0),
            size: CGSize(width: stage.width, height: 60)
        )
        band.anchorPoint = CGPoint(x: 0, y: 0)
        band.position = CGPoint(x: 0, y: stage.floorY + 40)
        band.zPosition = 1
        addChild(band)

        // Floor strip
        let floor = SKSpriteNode(
            color: SKColor(red: 0.3, green: 0.3, blue: 0.38, alpha: 1.0),
            size: CGSize(width: stage.width, height: stage.floorY)
        )
        floor.anchorPoint = CGPoint(x: 0, y: 0)
        floor.position = .zero
        floor.zPosition = 2
        addChild(floor)

        // Floor edge line
        let edge = SKSpriteNode(
            color: SKColor(red: 0.55, green: 0.55, blue: 0.65, alpha: 1.0),
            size: CGSize(width: stage.width, height: 2)
        )
        edge.anchorPoint = CGPoint(x: 0, y: 0)
        edge.position = CGPoint(x: 0, y: stage.floorY)
        edge.zPosition = 3
        addChild(edge)

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

        let rightWall = SKSpriteNode(
            color: wallColor,
            size: CGSize(width: stage.wallWidth, height: wallHeight)
        )
        rightWall.anchorPoint = CGPoint(x: 1, y: 0)
        rightWall.position = CGPoint(x: stage.width, y: stage.floorY)
        rightWall.zPosition = 4
        addChild(rightWall)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
