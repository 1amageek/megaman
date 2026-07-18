import Foundation
import OpenSpriteKit

// MARK: - AttackPreviewable
// Optional debug surface for `Attack` types so the boss preview UI can show
// which internal stage the state machine is currently in. The contract is
// read-only on purpose — stage transitions in Godot fire side effects
// (animation, velocity, screenshake, gravity_scale) at the *exit* of the
// previous stage rather than the *entry* of the next, so jumping into a stage
// from the outside without replaying those side effects leaves the boss
// visually inconsistent. Phase 1 exposes the stage label only; arbitrary
// stage jumping is intentionally deferred.
//
// Lives in the Attacks layer alongside `Attack` / `AttackContext` because the
// protocol is tied to attack-internal state. Conformances are written in the
// same .swift file as the conforming type so the file-private `Stage` enums
// don't need to be promoted to internal scope.
@MainActor
protocol AttackPreviewable: Attack {
    /// Stage labels in declaration order. The page renders these as a
    /// read-only timeline — clicking one is not supported (see file note).
    static var previewStageNames: [String] { get }

    /// Index of the active stage in `previewStageNames`, or -1 if the attack
    /// has finished (or has not started yet). Polled per frame by the page.
    var previewStageIndex: Int { get }
}
