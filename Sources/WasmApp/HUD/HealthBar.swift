import Foundation
import OpenSpriteKit

// MARK: - HealthBar
// Vertical segmented HP meter, drawn as stacked rects.
// Matches the Mega Man X series HUD convention (vertical on the side).

@MainActor
final class HealthBar: SKNode {
    enum Kind {
        case player
        case boss

        var fillColor: SKColor {
            switch self {
            case .player: return SKColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1.0)
            case .boss:   return SKColor(red: 1.0, green: 0.35, blue: 0.3, alpha: 1.0)
            }
        }
    }

    private let kind: Kind
    private let maxValue: CGFloat
    private let background: SKSpriteNode
    private let fill: SKSpriteNode
    private let border: SKSpriteNode
    private let barSize: CGSize

    // Fill animation state — when non-nil, `update(current:)` is ignored so
    // the animated ramp takes priority over the live HP read. Mirrors Godot
    // HUD.gd `fill_boss_hp` which drives `boss_hp.value` independently of
    // the boss's actual current_health until `boss_hp_filled` is set.
    private struct FillAnim {
        let target: CGFloat
        let duration: TimeInterval
        var elapsed: TimeInterval
    }
    private var fillAnim: FillAnim?
    var isFillAnimating: Bool { fillAnim != nil }

    init(kind: Kind, maxValue: CGFloat, size: CGSize = CGSize(width: 8, height: 64)) {
        self.kind = kind
        self.maxValue = maxValue
        self.barSize = size
        self.background = SKSpriteNode(color: SKColor(white: 0.1, alpha: 1.0), size: size)
        self.fill = SKSpriteNode(color: kind.fillColor, size: size)
        self.border = SKSpriteNode(color: SKColor(white: 0.75, alpha: 1.0),
                                   size: CGSize(width: size.width + 2, height: size.height + 2))
        super.init()
        border.zPosition = 0
        background.zPosition = 1
        fill.zPosition = 2
        fill.anchorPoint = CGPoint(x: 0.5, y: 0)
        fill.position = CGPoint(x: 0, y: -size.height / 2)
        addChild(border)
        addChild(background)
        addChild(fill)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(current: CGFloat) {
        // Defer to the scripted fill ramp while one is running, otherwise
        // reflect the live value. Without this guard, the bar would snap
        // to `maxHealth` on the first post-appear tick since the animation
        // would be clobbered by the per-frame `update(current: boss.currentHealth)`.
        if fillAnim != nil { return }
        applyRatio(current / maxValue)
    }

    /// Kick off a scripted fill animation from 0 → `target` over `duration`
    /// seconds. Mirrors Godot HUD.gd `fill_boss_hp` (1 step per 0.033s, 32
    /// steps → ~1.056s total). While active, `update(current:)` no-ops.
    func startFillAnimation(to target: CGFloat, duration: TimeInterval = 1.056) {
        fillAnim = FillAnim(target: target, duration: duration, elapsed: 0)
        applyRatio(0)
    }

    /// Advance the scripted fill ramp by `dt`. Scene ticks this during intro.
    func tickFillAnimation(_ dt: TimeInterval) {
        guard var anim = fillAnim else { return }
        anim.elapsed += dt
        let t = max(0, min(1, CGFloat(anim.elapsed / anim.duration)))
        applyRatio((anim.target * t) / maxValue)
        if t >= 1.0 {
            fillAnim = nil
        } else {
            fillAnim = anim
        }
    }

    private func applyRatio(_ raw: CGFloat) {
        let ratio = max(0, min(1, raw))
        fill.size = CGSize(width: barSize.width, height: barSize.height * ratio)
    }
}
