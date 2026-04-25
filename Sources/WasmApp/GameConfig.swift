import Foundation

// MARK: - Game Resolution

enum GameConfig {
    // Native resolution — matches Mega-Man-X8-16-bit Godot project.godot viewport
    static let gameWidth: Int = 398
    static let gameHeight: Int = 224
    static let floorY: CGFloat = 28
}

// MARK: - Physics Constants
// Source: Mega-Man-X8-16-bit/src/Actors/Actor.gd + Modules/Movement.gd

enum PhysicsConstants {
    static let gravity: CGFloat = 900
    static let maxFallVelocity: CGFloat = 375
    static let playerWalkSpeed: CGFloat = 90
    static let playerJumpVelocity: CGFloat = 320
    static let playerDashSpeed: CGFloat = 210       // Player.tscn Dash horizontal_velocity
    static let playerDashDuration: TimeInterval = 0.55    // Player.gd line 208 override
    static let playerAirDashDuration: TimeInterval = 0.475 // AirDash.gd default (no Player.gd override)
    static let playerJumpMaxTime: TimeInterval = 0.625     // Jump.gd max_jump_time
    static let playerJumpFullspeedProportion: CGFloat = 0.19 // Jump.gd fullspeed_proportion
    static let playerMaxHealth: CGFloat = 16      // Player.tscn max_health = 16.0
    static let damageFlashDuration: TimeInterval = 0.034
    // Damage.gd on Player.tscn: invulnerability_time = 1.75, duration_time = 0.6.
    // Knockback values inherit from Modules/Movement.gd defaults:
    //   horizontal_velocity = 90, jump_velocity = 320 (Damage.gd reads these
    //   via the shared Movement module, not Player-specific overrides).
    static let invulnerabilityDuration: TimeInterval = 1.75
    static let bossNormalInvulnerabilityDuration: TimeInterval = 0.06
    static let hurtDuration: TimeInterval = 0.6
    static let hurtKnockbackX: CGFloat = 90
    static let hurtKnockbackY: CGFloat = 320
}

// MARK: - Wall mechanics
// Source: Mega-Man-X8-16-bit/Wallslide.gd + Walljump.gd

enum WallSlideConstants {
    // WallSlide.gd start_delay = 0.16 s. During this window the body is held
    // against the wall and gravity continues to accumulate; after the delay,
    // `set_vertical_speed(jump_velocity)` ASSIGNS velocity.y to jump_velocity
    // — Player.tscn WallSlide node overrides jump_velocity = 90 (NOT the 320
    // default in Movement.gd), so this is a slow controlled descent.
    static let startDelay: TimeInterval = 0.16
    // Player.tscn WallSlide node `jump_velocity = 90.0` — magnitude of the
    // downward slide speed. Y-up port → -slideSpeed.
    static let slideSpeed: CGFloat = 90
}

enum WallJumpConstants {
    // Walljump.gd start_delay default = 0.128 s, overridden to 0.116 s by
    // Player.tscn's WallJump node. During this window: locked vy = 0, vx = 0,
    // no Jump.gd super behaviour (no slowdown ascent yet).
    static let startDelay: TimeInterval = 0.116
    // move_away_duration default = 0.08 s, overridden to 0.15 s by Player.tscn.
    // Between [start_delay, start_delay + move_away_duration] the player drifts
    // away from the wall at move_away_speed before normal Jump.gd ascent kicks
    // in.
    static let moveAwayDuration: TimeInterval = 0.15
    static let moveAwaySpeed: CGFloat = 75
}

// MARK: - Boss Constants
// Source: Mega-Man-X8-16-bit/src/Actors/Bosses/BossAI.gd + SatanSigma/*.gd

enum BossConstants {
    static let maxHealth: CGFloat = 260
    static let desperationThreshold: CGFloat = 0.5
    // Sigma.tscn BossAI.time_between_attacks = Vector2(0.25, 0.65).
    // x = floor (used at low HP), y = ceiling (used at full HP).
    static let attackCooldownMin: TimeInterval = 0.25
    static let attackCooldownMaxAtFullHP: TimeInterval = 0.65
}

// MARK: - Weapon Constants
// Source: Mega-Man-X8-16-bit/src/Actors/Weapons/Projectiles/WeaponShot.gd

enum WeaponConstants {
    static let lemonSpeed: CGFloat = 360
    static let lemonLifetime: TimeInterval = 0.4
    static let lemonDamage: CGFloat = 1
    static let maxLemonsAlive: Int = 3
    // Medium / Charged Buster — Godot Buster.tscn shots[1] / shots[2].
    static let mediumBusterSpeed: CGFloat = 360    // WeaponShot.gd default horizontal_velocity
    static let mediumBusterDamage: CGFloat = 5     // Medium Buster.tscn damage = 5.0
    static let mediumBusterLifetime: TimeInterval = 1.2
    static let chargedBusterSpeed: CGFloat = 420   // Charged Buster.tscn horizontal_velocity = 420.0
    static let chargedBusterDamage: CGFloat = 10   // Charged Buster.tscn damage_to_bosses = 10.0
    static let chargedBusterLifetime: TimeInterval = 1.4
    // Charge timing — Godot Charge.gd (minimum_charge_time, level_3_charge, level_4_charge).
    // Only levels 0..2 ship for Sigma battle (arm_cannon.upgraded is out of scope).
    static let chargeMidThreshold: TimeInterval = 0.5
    static let chargeFullThreshold: TimeInterval = 1.75
    static let sigmaBallSpeed: CGFloat = 240       // SigmaWave.tscn speed = 240.0
    static let sigmaBallDamage: CGFloat = 10       // SigmaWave.tscn damage = 10.0
    static let sigmaLanceDamage: CGFloat = 12      // Lance.tscn damage = 12.0
    // Godot `Lance.gd` is a stationary hazard — Sigma's raycast picks the
    // collision point and the lance just materialises there, with staggered
    // trail sprites suggesting arrival. Without those trails the strike reads
    // as a pop-in, so the port flies the lance along the aimed vector at a
    // speed tuned to cross ~half the arena in 0.4 s.
    static let sigmaLanceSpeed: CGFloat = 520
    static let sigmaLanceLifetime: TimeInterval = 1.2
    static let sigmaLaserDamage: CGFloat = 28      // SigmaLaser.tscn damage = 28.0
    static let sigmaMeleeDamage: CGFloat = 12      // Sigma.tscn melee damages = 12.0
    static let sigmaContactDamage: CGFloat = 8     // Sigma.tscn DamageOnTouch.damage = 8.0
}

// MARK: - Collision Categories
// Source: Mega-Man-X8-16-bit/project.godot layer_names

enum PhysicsCategory {
    static let none: UInt32 = 0
    static let scenery: UInt32 = 1 << 0
    static let player: UInt32 = 1 << 1
    static let playerProjectile: UInt32 = 1 << 2
    static let enemy: UInt32 = 1 << 3
    static let enemyProjectile: UInt32 = 1 << 4
}
