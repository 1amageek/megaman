import Foundation
import OpenSpriteKit

// MARK: - PlayerWorld
// Scene-callback seam used by Player to request behaviours that live on the
// BossBattleScene (wall-pillar contact lookup, projectile spawning) without
// Player having to import a concrete Scene type. PlayerPreviewScene does NOT
// adopt this protocol — Player.world stays nil there and the call sites
// short-circuit via optional chaining. See ARCHITECTURE.md §3.2.

@MainActor
protocol PlayerWorld: AnyObject {
    /// Reports which side of the player's hitbox is in contact with an inner
    /// arena pillar (`SigmaWall`), if any. Mirrors the wall-contact lookup
    /// that the battle scene performs against its `sigmaWalls` array.
    func sigmaWallContact(for playerHitbox: CGRect) -> Facing?

    /// Spawns a player buster shot at the supplied muzzle position. The
    /// concrete projectile is selected from `chargeLevel` (0=lemon, 1=medium,
    /// 2=charged) and registered with the scene's projectile list so its
    /// hitbox participates in collision resolution.
    func spawnPlayerShot(chargeLevel: Int, from origin: CGPoint, facing: Facing)
}
