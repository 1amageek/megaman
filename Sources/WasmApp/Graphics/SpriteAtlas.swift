import Foundation
import OpenSpriteKit

// Sliced atlas keyed by Aseprite frameTag name.
// Each entry holds the in-order list of subtextures for one animation
// plus the average per-frame duration in seconds.

struct SpriteAnimation {
    let textures: [SKTexture]
    let timePerFrame: TimeInterval

    var duration: TimeInterval { timePerFrame * TimeInterval(textures.count) }
}

@MainActor
final class SpriteAtlas {
    let parentTexture: SKTexture
    private(set) var animations: [String: SpriteAnimation] = [:]

    init(parentTexture: SKTexture, animations: [String: SpriteAnimation]) {
        self.parentTexture = parentTexture
        self.animations = animations
    }

    func animation(_ name: String) -> SpriteAnimation? {
        animations[name]
    }

    static func make(pngData: Data, atlas: AsepriteAtlas) -> SpriteAtlas? {
        guard let parent = SKTexture(imageData: pngData) else { return nil }

        let parentSize = parent.size()
        let pw = max(parentSize.width, 1)
        let ph = max(parentSize.height, 1)

        // Pre-slice each frame as a unit-coordinate subtexture once.
        var sliced: [SKTexture] = []
        sliced.reserveCapacity(atlas.frames.count)
        for f in atlas.frames {
            let unit = CGRect(
                x: CGFloat(f.frame.x) / pw,
                y: CGFloat(f.frame.y) / ph,
                width: CGFloat(f.frame.w) / pw,
                height: CGFloat(f.frame.h) / ph
            )
            sliced.append(SKTexture(rect: unit, in: parent))
        }

        var anims: [String: SpriteAnimation] = [:]
        for tag in atlas.meta.frameTags {
            let lo = max(0, min(tag.from, atlas.frames.count - 1))
            let hi = max(0, min(tag.to, atlas.frames.count - 1))
            guard lo <= hi else { continue }

            let range = lo...hi
            let frames = Array(sliced[range])
            let durations = atlas.frames[range].map { $0.duration }
            let avgMs = durations.isEmpty ? 100 : durations.reduce(0, +) / durations.count
            anims[tag.name] = SpriteAnimation(
                textures: frames,
                timePerFrame: TimeInterval(avgMs) / 1000.0
            )
        }

        return SpriteAtlas(parentTexture: parent, animations: anims)
    }

    /// Build an atlas from a bare PNG sliced as a `cols × rows` uniform grid
    /// into one animation tag. Used for Godot effect textures that ship
    /// without Aseprite JSON (sparks/death/dash/smoke/airdash, plus single-
    /// frame PNGs like circle/light with cols=rows=1).
    static func makeGrid(
        pngData: Data,
        cols: Int,
        rows: Int,
        frameDurationMs: Int,
        tag: String
    ) -> SpriteAtlas? {
        guard cols > 0, rows > 0 else { return nil }
        guard let parent = SKTexture(imageData: pngData) else { return nil }

        let cellW = 1.0 / CGFloat(cols)
        let cellH = 1.0 / CGFloat(rows)
        var textures: [SKTexture] = []
        textures.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let unit = CGRect(
                    x: CGFloat(c) * cellW,
                    y: CGFloat(r) * cellH,
                    width: cellW,
                    height: cellH
                )
                textures.append(SKTexture(rect: unit, in: parent))
            }
        }

        let anim = SpriteAnimation(
            textures: textures,
            timePerFrame: TimeInterval(frameDurationMs) / 1000.0
        )
        return SpriteAtlas(parentTexture: parent, animations: [tag: anim])
    }
}
