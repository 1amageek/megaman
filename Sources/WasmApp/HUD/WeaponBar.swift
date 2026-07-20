import Foundation
import OpenSpriteKit

// MARK: - WeaponBar
// Top-left HUD slot showing the equipped weapon and current charge level.
// v1 carries only X-Buster, so the icon is a static "X" plate; the three
// segment gauge to the right reflects Player.chargeLevel (0/1/2).

final class WeaponBar: SKNode {
    private let iconBg: SKSpriteNode
    private let iconBorder: SKSpriteNode
    private let iconLabel: SKLabelNode
    private let segments: [SKSpriteNode]
    private var lastChargeLevel: Int = -1
    private static let segmentLitColor =
        SKColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1.0)
    private static let segmentDimColor =
        SKColor(white: 0.18, alpha: 1.0)

    override init() {
        let iconSize = CGSize(width: 14, height: 14)
        self.iconBg = SKSpriteNode(color: SKColor(white: 0.08, alpha: 1.0), size: iconSize)
        self.iconBorder = SKSpriteNode(
            color: SKColor(white: 0.75, alpha: 1.0),
            size: CGSize(width: iconSize.width + 2, height: iconSize.height + 2)
        )
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = "X"
        label.fontSize = 11
        label.fontColor = SKColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1.0)
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = .zero
        self.iconLabel = label

        let segmentSize = CGSize(width: 4, height: 12)
        self.segments = (0..<3).map { _ in
            SKSpriteNode(color: WeaponBar.segmentDimColor, size: segmentSize)
        }

        super.init()

        iconBorder.zPosition = 0
        iconBg.zPosition = 1
        iconLabel.zPosition = 2
        addChild(iconBorder)
        addChild(iconBg)
        addChild(iconLabel)

        for (i, seg) in segments.enumerated() {
            seg.position = CGPoint(x: iconSize.width / 2 + 6 + CGFloat(i) * (segmentSize.width + 1),
                                   y: 0)
            seg.anchorPoint = CGPoint(x: 0, y: 0.5)
            seg.zPosition = 1
            addChild(seg)
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Update the segment gauge from the player's current charge level.
    /// Level 0 (none) lights nothing, level 1 (mid) lights one segment, level
    /// 2 (full) lights all three so the visual climbs as the meter climbs.
    /// Short-circuits when the level hasn't changed — touching `.color` on
    /// every frame allocates fresh CGColor state and starves WASM heap.
    func update(chargeLevel: Int) {
        if chargeLevel == lastChargeLevel { return }
        lastChargeLevel = chargeLevel
        let lit = chargeLevel >= 2 ? 3 : (chargeLevel >= 1 ? 1 : 0)
        for (i, seg) in segments.enumerated() {
            seg.color = i < lit ? WeaponBar.segmentLitColor : WeaponBar.segmentDimColor
        }
    }
}
