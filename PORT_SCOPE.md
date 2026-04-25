# megaman — Full Port Scope Analysis

Comprehensive gap analysis for porting **Mega Man X8 (16-bit fangame)** from Godot/GDScript (`Mega-Man-X8-16-bit/`) to Swift + OpenSpriteKit + WASM (`megaman/`).

> This document complements `REQUIREMENTS.md` (which scopes the current v1 Sigma-only target). `PORT_SCOPE.md` covers the full-game scope so we can plan beyond v1.

## Executive summary

| | Godot reference | Swift port |
|---|---|---|
| GDScript / Swift files | ~986 | 22 |
| LOC | ~57,984 | ~2,514 |
| Coverage (by LOC) | 100% | **~4%** |
| Bosses | 12 | 1 (Sigma ~60%) |
| Stages | 10 | 1 flat arena (~10%) |
| Enemies | 34 types | 0 |

Player basics are well-architected. The remaining ~96% of the work splits roughly: bosses 60% / stages 20% / UI & progression 15% / polish 5%.

---

## Domain-by-domain gap table

| Domain | Godot scope | Swift status | Priority | Effort |
|---|---|---|---|---|
| Player (X) | 15+ ability modules | ~70% | P0 | Moderate |
| Regular enemies | 34 types under `src/Actors/Enemies/` | 0% | P1 | Massive |
| Bosses | 12 bosses, each with 7–26 ability files | Sigma ~60%, others 0% | P0 → P1 | Massive |
| Stages / levels | 10 `.tscn` scenes + tilemaps | Sigma arena ~10% | P1 | Massive |
| Weapons / projectiles | Buster 3 tiers + 8 boss weapons | Buster ~70% | P1 | Large |
| HUD / UI | Health / boss / weapon bars + menus | Health bar only ~40% | P0 → P1 | Large |
| Camera | Zone-based X8Camera + parallax | 0% | P1 | Moderate |
| Save / Load | Binary savefile + 3 slots | 0% | P2 | Moderate |
| Audio | 610 audio files + music manager | 0% | P1 | Moderate |
| Particles / VFX | ParticleCache + shaders | 0% | P2 | Moderate |
| Input | Keyboard + gamepad + remap | ~60% (keyboard only) | P0 | Small |
| Meta (achievements / IGT / cheats) | Achievements.gd, IGT.gd, cheats | 0% | P3 | Moderate |
| Rendering pipeline | Aseprite import + palette shaders | ~70% pipeline, 0% polish | P0 | Moderate |
| Physics / collision | Tilemap + multi-layer collision | Flat floor ~50% | P1 | Large |
| Cutscenes / story | Dialog system + intros + ending | 0% | P2 | Large |

---

## 1. Player character (X)

### Godot scope
- Root ability modules: `Walk.gd`, `Jump.gd`, `Dash.gd`, `DashJump.gd`, `DashWallJump.gd`, `AirDash.gd`, `Fall.gd`, `Idle.gd`, `Charge.gd`, `Shot.gd`, `Damage.gd`, `Turn.gd` (~15 abilities)
- `Player.gd` (~300 LOC): Character → AbilityUser, BaseAbility priority scheduler
- `Weapon.gd`: arm cannon, shot lifecycle, palette swap per charge level
- `Armor.gd`: damage reduction with 3 parts (Head / Body / Legs)
- `Subtank.gd` + `SubtankManager.gd`: healing reserves

### Swift port status
**Implemented:** `PlayerState` enum (9 states), gravity/velocity integration, floor detection, keyboard input (arrows + X/Z/C), lemon+medium+charged shots with cooldown, facing flip, `takeDamage` with i-frames.

**Missing:**
- Wall slide (`Wallslide.gd`)
- Wall jump (full version — current implementation is a skeleton)
- Turn animation (facing-flip transition)
- Slide / Crouch / Climb
- Damage i-frame visuals (flash / palette swap)
- Armor parts system
- Subtanks (healing items)
- 8 boss weapons + switching system
- Weapon energy / ammo tracking

### Effort: **Moderate** — each ability is a 50–150 LOC state machine.

---

## 2. Regular enemies

### Godot scope
34 enemy types under `src/Actors/Enemies/`:

- Small: Bee, Fly, Bee variants
- Medium: Fish, Drone, GroundPizza, CospeBola, BikeReploid, Conjunctivite, LaserLine
- Big: BigMechaniloid, Big Tractor, Artificial Intelligence
- Specialized: GrabAttack, InstantTurn, Shield, Missile

Shared base: `BaseEnemy.tscn`, `EnemyAbility.gd`, `AI.gd` behavior trees, `EnemyShot.gd`, `EnemyStun.gd`. Spawning via `AlarmSpawner.gd`. Each enemy has 2–5 abilities.

### Swift port status
None. Sigma arena has no regular enemy spawns.

### Effort: **Massive** — 34 × 100–300 LOC + spawner ≈ 5,000+ LOC.

---

## 3. Bosses

### Godot scope — all 12 playable bosses

| Boss | Moveset size | Signature attacks |
|---|---:|---|
| Satan Sigma | 12 | GroundCombo, JumpCombo, LanceThrow, AirCombo, OverdriveAttack, SigmaLaser, SigmaWall |
| Lumine | 26 | 8+ phases, stun-lock combos, energy projectiles, invulnerability cycles |
| Bamboo Pandamonium | 20 | Rolling attacks, ground pound, spike traps, panic dash |
| Vile | 19 | Gun combos, charge shot, knockback spam, desperation |
| Earthrock Trilobyte | 19 | Burrow, spike launch, terrain deformation |
| Gigabolt Man-O-War | 15 | Electrical aura, beam attacks, invuln phases |
| Gravity Antonion | 14 | Gravity well, crush attacks, desperation |
| Optic Sunflower | 13 | Laser patterns, charge-up, reflect shield |
| Copy Sigma | 13 | Copies X's weapons, multi-phase |
| Giant Mechaniloid | 12 | Arm cannon, stomp, platform destruction |
| Burn Rooster | 12 | Fire attacks, flight phase, desperation |
| King Crab | 7 | Claw swipes, shell spin, desperation |
| Avalanche Yeti | 2 | Limited moveset (test boss) |

Shared infrastructure: `BossAI.gd` (~280 LOC priority scheduler + RNG + desperation), `BossIntro.gd` + `GenericIntro.gd` (landing + "BATTLE" splash), `BossStun.gd`, per-boss projectile sprites, weakness chains.

### Swift port status
**Sigma only:** `Boss.swift`, `BossAI.swift` (4 of 7 attacks: GroundCombo / JumpCombo / LanceThrow / AirCombo), `OverdriveAttack.swift`, `Projectile.swift` (colored rectangles, no atlas).

**Missing:** 11 other bosses (zero assets or logic), intro cutscenes, boss sprite animations, stun visuals, phase transitions (Lumine), weakness chain.

### Effort: **Massive** — 11 × ~1,000+ LOC each = 15,000+ LOC of attacks + assets.

---

## 4. Stages / levels

### Godot scope
Boss / hub / palace stages:

- `BoosterForest` · `Dynasty` · `Inferno` · `KinematicCamera` · `MetalValley` · `NoahsPark` · `Primrose` · `TroiaBase` · `CentralWhite` · `SigmaPalace` · `Gateway` (hub)

Stage infrastructure:
- `Stage.gd` — stage loader, checkpoint system
- `StageSegmentManager.gd` — tilemap segmentation for memory
- Tiled tilemaps (`tileset_*.ase`)
- `MovingPlatform.gd` — destructible / elevating
- `Checkpoint.gd` — respawn + save state
- Per-region camera zones, cinematic pans

### Swift port status
`Stage.swift` — minimal (width, height, floorY, spawn points). `StageBackdrop` — placeholder colored rectangles. `BossBattleScene.swift` — flat arena, no tilemap.

**Missing:** 9 other stages, tilemap loader, moving platforms, checkpoints, camera zones, destructible objects / hazards, stage intros, hub, transitions.

### Effort: **Massive** — stage loader + 10 × ~1,500 LOC ≈ 20,000+ LOC.

---

## 5. Weapons / projectiles

### Godot scope
- Buster tiers: Lemon / Medium Buster / Charged Buster
- 8 boss weapons: BlastLauncher, CrystalBouncer, DarkArrow, DriftDiamond, FireDash, GigaCrash, OpticShield, SqueezeBomb, ThunderDancer, XDrive
- `Weapon.gd` (~150 LOC): ammo tracking, rate limit, palette swap (MainColor1–6), shot lifecycle signals

### Swift port status
`Buster` tiers wired in `ProjectileKind` with factory helpers + `spawnPlayerShot(chargeLevel:)` dispatch. All still rendered as colored rectangles.

**Missing:** Boss weapon pickup, weapon-switch UI, ammo tracking, weapon-specific sprites + behavior, palette swap.

### Effort: **Large** — weapon system + 8 × ~200 LOC ≈ 2,500 LOC.

---

## 6. HUD / UI

### Godot scope
- `Hud.tscn` master scene: HealthBar (`IGScreen.gd`, ~200 LOC), BossBar (`BossBar.gd`), WeaponBar + wheel (`WeaponBar.gd`), BossOrder grid, DebugAndCheats
- Menus: title (`DisclaimerScreen.gd`), stage select (`BossOrder.tscn`), pause, game over / continue, file select (3 slots)
- Cutscenes: boss landing intro (`GenericIntro.gd`), victory / weapon-get, ending

### Swift port status
`HealthBar.swift` — player + boss bars with pip animation (~40%).

**Missing:** weapon select UI, title, stage select, pause menu, game over, file select, boss intro splash, victory sequence, dialogue system.

### Effort: **Large** — menus + dialogue + cutscenes ≈ 3,000+ LOC.

---

## 7. Camera

### Godot scope
`X8Camera.gd` (~150 LOC): zone-based, modes `CameraFollowPlayer` · `CameraDirectTranslate` · `CameraTranslate` · `CameraZoneTranslate`. Multi-layer parallax (`ForegroundBrightnessMatch.gd`). Boss-locked framing during intros.

### Swift port status
None. `BossBattleScene` uses fixed viewport.

**Missing:** follow camera, zone boundaries, parallax, cinematic pans, screen shake.

### Effort: **Moderate** — controller + parallax ≈ 800 LOC.

---

## 8. Save / Load

### Godot scope
`Savefile.gd` (~120 LOC), binary at `user://savegame.save`. Persists GlobalVariables (lives, ammo), achievements, collectibles, input bindings. Save triggers: level transition, checkpoint, menu exit. Load-on-startup with version check. 3 save slots.

### Swift port status
None.

**Missing:** browser storage (LocalStorage / IndexedDB), persistent state schema, 3 slots, startup load.

### Effort: **Moderate** — ~300 LOC + storage-API decision.

---

## 9. Audio

### Godot scope
610 audio files in `src/Sounds/`:
- BGM: stage intros (12+), boss themes (12+), stage select, title
- SFX: shot tiers, dash, jump, damage, explosion (boss-specific), charge-up, weapon pickup
- Voice cues (sparse)

Management: `music_player.gd` per-level BGM, crossfade on level change, looping. SFX fired from Actor / Weapon events.

### Swift port status
None.

**Missing:** audio file hosting (Vapor static routes), BGM loader + playback, SFX pool, volume controls.

### Effort: **Moderate** — ~500 LOC + asset-serving infra. WASM audio codec compatibility is a risk.

---

## 10. Particles / VFX

### Godot scope
`ParticleCache.gd` sprite pooling. Effects: muzzle flash, explosion, dust (landing/dashing), charge aura, damage flash, screen shake. Shaders: `flash_shader.tres`, `charge_shader.tres`, `Armor_Material_Shader.tres` (palette swap), optional CRT.

### Swift port status
None. Only `SKSpriteNode` color tinting.

### Effort: **Moderate** — particle + shader framework ≈ 1,000 LOC.

---

## 11. Input

### Godot scope
`InputManager.gd` (~200 LOC): keyboard (arrow / X jump / Z dash / C shoot / A weapon-select), Xbox gamepad, remapping UI → Savefile. `InputPressCombo.gd` for charge-press sequences.

### Swift port status
`InputManager.swift` — keyboard polling, arrow keys + X/Z/C, no gamepad, no remap UI (~60%).

### Effort: **Small** — gamepad + remap UI ≈ 400 LOC.

---

## 12. Meta systems

### Godot scope
`Achievements.gd` + `AchievementManager.gd` (~500 LOC, 33 achievements, Event-system triggers, persistent). `IGT.gd` in-game timer / speedrun tracking. `CheatEngine.gd` (invincibility, skip levels). Difficulty scaffold (not fully wired).

### Swift port status
None.

### Effort: **Moderate** — achievements + timer ≈ 600 LOC, cheats ≈ 200 LOC.

---

## 13. Rendering / graphics

### Godot scope
Aseprite → JSON + PNG via AsepriteWizard addon. Per-character atlases (`x.json`, `sigma.json`, …). Viewport 398×224 (SNES), scaled 1194×672. Filter off (nearest neighbor).

### Swift port status
- `AsepriteAtlas.swift` — Codable parsing of array-form JSON
- `SpriteLoader.swift` — async fetch + PNG decode + slicing
- `SpriteAtlas.swift` — frame-tag → `[SKTexture]`
- Player atlas hooked up via `attachAtlas` + `playAnimation`
- Server-side asset routing (~70% pipeline, ~0% visual polish)

**Missing:** boss sprite atlases loaded, stage backdrop art, particle sprite rendering, palette-swap shaders, CRT filter, aspect-ratio fit.

### Effort: **Moderate** — asset server hookups + stage art ≈ 600 LOC + infra.

---

## 14. Physics / collision

### Godot scope
Manual physics (no rigid bodies): `Actor.gd` gravity 800 / max fall 375, tilemap solid layers, one-way platforms, damage zones (death pits / hazards), moving-platform logic. Collision layers 1 (scenery) / 2 (player) / 3 (player proj) / 4 (enemy) / 5 (enemy proj) / 9–11 (wall subtypes).

### Swift port status
`Actor.swift` — gravity, integration, floor-Y clamping (~50%). Simple AABB projectile ↔ actor (~10%).

**Missing:** tilemap collision, one-way platforms, damage zones, moving platforms, multi-layer queries, projectile ↔ enemy, wall climb/slide.

### Effort: **Large** — tilemap loader + collision grid ≈ 2,000 LOC.

---

## 15. Cutscenes / story

### Godot scope
Dialog system (`DialogBox.tscn` + 15+ `.tres` resources per stage / boss, queued, input-advanced). Intro (`IntroCapcom.tscn`, `IntroBGAnim.gd`, `IntroANim.gd` ~200 LOC). Boss intros (`GenericIntro.gd` landing + "BATTLE" splash, optional dialogue). Ending (victory + weapon get + credits).

### Swift port status
None.

### Effort: **Large** — dialogue engine + cutscenes ≈ 2,500 LOC.

---

## Key blockers & decisions

### Asset pipeline
- Player atlas loading works (fetch + decode). Boss sprites (`sigma_ball`, `sigma_lance`, `sigma_laser`) assets exist under `Public/assets/sprites/boss/` but are **not wired** — projectiles still render as colored rectangles.
- Stage artwork is a placeholder.

### Tilemap collision
Three viable paths, pick one before attempting Phase 2:

| Option | Cost | Trade-off |
|---|---|---|
| Full Tiled loader | ~1,500 LOC | Matches Godot authoring flow, but largest upfront spend |
| Hardcoded 2D arrays per stage | ~200 LOC / stage | Fast to bootstrap; authoring pain scales linearly |
| Skip stages entirely, stay boss-battle-only | 0 LOC | Limits scope to arcade mode permanently |

### Audio format & hosting
610 OGG/WAV files must stream from Vapor. ~200 LOC server + upload + browser audio API. Risks: latency, caching, WASM codec compatibility.

### WASM binary size
Current Sigma-only ≈ 3 MB. Full game + assets estimated 10–20 MB. Mitigations: lazy-load per boss, WebP over PNG, split WASM modules.

### Full vs. single-boss scope
Full game = 12 bosses × 1,000–2,000 LOC each = 15,000+ LOC of logic + art. Recommend holding the Sigma-only line for v1.

---

## Roadmap

### Phase 1 — Sigma arcade mode *(current target)*
Minimum playable single-boss fight. **~20 days remaining.**

- Sigma sprite atlas hookup — 2 d
- Player animation tags (Turn / AirDash / WallJump) — 3 d
- Intro cutscene ("BATTLE" splash) — 2 d
- Victory / defeat screens + restart flow — 3 d
- BGM + key SFX — 4 d
- Gamepad input (Xbox layout) — 1 d
- Collision / animation polish — 3 d

### Phase 2 — One complete stage + boss
**6–8 weeks, +5,000–8,000 LOC.**

- Tilemap integration (collision + moving platforms)
- Enemy spawning (5–10 types, not all 34)
- Full HUD (weapon select, boss bar, life/ammo tracking)
- Flow: Title → Stage Select → Stage → Boss → Victory
- Pause menu, continue logic

### Phase 3 — Full game (8 bosses + all stages)
**4–6 months, +20,000–30,000 LOC.**

- 11 remaining bosses + movesets
- 9 remaining stages with unique challenges
- 8 boss weapons (pickup + switch)
- Save / Load (3 slots)
- Full audio (BGM + SFX)
- Achievements (33+)
- Ending sequence

### Phase 4 — Polish *(optional)*
**2–4 weeks, +3,000–5,000 LOC.**

- Screen shake, particle effects
- CRT shader, palette swaps
- Gamepad remap UI
- Difficulty modes, cheats
- Secret / bonus content

---

## Codebase metrics

| | Godot | Swift | Ratio |
|---|---:|---:|---:|
| Source files | 986 | 22 | 45:1 |
| Total LOC | 57,984 | 2,514 | 23:1 |
| Actor / Character | ~1,500 | ~350 | 4:1 |
| Systems (AI / Save / …) | ~3,000 | ~600 | 5:1 |
| UI / HUD | ~2,000 | ~150 | 13:1 |
| Boss movesets | ~8,000 | ~400 (Sigma) | 20:1 |
