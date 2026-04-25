import Foundation
import OpenSpriteKit

// Global registry for Godot-sourced effect sprite sheets loaded at boot. The
// CLAUDE.md "sprites MUST come from the atlas" rule requires Player/Boss
// effect factories to render from these sheets rather than compose effects
// from flat-color SKSpriteNode primitives. Each kind maps to a bare PNG
// sliced as a uniform grid via `SpriteLoader.loadGrid` (Godot's atlas PNGs
// ship without Aseprite JSON; the cols/rows come from the Godot
// `ParticleProcessMaterial` + `TextureAtlas` H/V frame counts).
@MainActor
enum EffectAtlases {
    enum Kind: String {
        case sparks            // sparks.png            3x2 (Damage.tscn sparks AnimatedSprite2D)
        case circle            // circle.png            1x1 (Charge / charge-ring halo)
        case dash              // dash.png              3x2 (Dash.gd ground dust)
        case smoke             // smoke.png             3x3 (Walk.gd ground dust, WallJump contact)
        case airdash           // airdash.png           3x2 (AirDash.gd kick-off)
        case death             // death.png             3x2 (X Death Particles xdeath burst)
        case light             // light.png             1x1 (flash.gd generic white flash)
        case sigmaTrail        // sigma_trail.png       1x9 (Lance.tscn trail/trail2/trail3/trail4)
        case sigmaParticle     // sigma_particles.png   1x1 (Lance.tscn evilfire_particles drifting sparks)
        case sigmaParticleAnim // sigma_particles2.png  3x3 (Lance.tscn firetip animated flame)
    }

    private static var atlases: [Kind: SpriteAtlas] = [:]

    static func register(_ atlas: SpriteAtlas, for kind: Kind) {
        atlases[kind] = atlas
    }

    static func atlas(_ kind: Kind) -> SpriteAtlas? {
        atlases[kind]
    }

    // Returns the single animation from a loadGrid-produced atlas (tag="all").
    static func animation(_ kind: Kind) -> SpriteAnimation? {
        atlases[kind]?.animations.first?.value
    }
}
