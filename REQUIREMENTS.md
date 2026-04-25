# megaman — Boss Battle Reproduction Requirements

Goal: faithfully reproduce **one boss battle** from `Mega-Man-X8-16-bit/` (Godot/GDScript) on top of OpenSpriteKit, running in the browser via WebAssembly.

## Target boss

**Sigma (Satan Sigma).** This is the only boss for which we have authored sprite assets in `Public/assets/sprites/boss/` (`satan_sigma`, `sigma_ball`, `sigma_lance`, `sigma_laser`). King Crab has logic in `KingCrabArmShot.gd` upstream but no atlas, so it is out of scope for v1.

---

## P0 — Must-have for "looks like the original"

### Sprite rendering pipeline
- Static asset hosting: Vapor server must serve `Public/assets/**` to the browser.
- `AsepriteAtlas` Codable types for the Aseprite v1.3-beta14 array-form JSON (`frames[]` + `meta.frameTags[]`).
- `SpriteLoader` async API: fetch PNG + JSON, decode PNG via `SKTexture(imageData:)`, slice subrects via `SKTexture(rect:in:)`, group by `frameTag.name` → `[String: [SKTexture]]`.
- Frame durations: per-frame `duration` (ms) is honored; we expose either an average `timePerFrame` or a non-uniform `SKAction.sequence`. v1 uses average.

### Player visuals
- Replace `Player.updateVisual()` color hack with `playAnimation(tag:)` driven by Aseprite atlas tags.
- State → tag map (from `x.json`):
  - `idle` → `idle` (30–32, 3 frames)
  - `walk` → `walk` (68–79, 12 frames). `walk_start` (66–67) optionally as a transition.
  - `jump` → `jump` (80–83)
  - `fall` → `fall` (84–87)
  - `dash` → `dash` (88–91)
  - `airdash` → `airdash` (163–165)
  - `hurt` → `damage` (138–146)
  - `shot` → `shot` (98–99) — overlay/transient on top of base state
  - `turn` → `turn` (210–214) — transition between facings
  - `slide`/wall hold → `slide` (120–123)
  - `walljump` → `walljump` (124–128)

### Player abilities (still missing relative to Godot reference)
- `Turn.gd` → brief facing-change animation that locks input
- `AirDash.gd` → mid-air horizontal dash, single-use per jump
- `Wallslide.gd` → slow descent while holding into a wall
- `Walljump.gd` → kickoff away from a wall

### Boss visuals
- Sigma idle/walk/attack/hurt animations from `satan_sigma.json`.
- Boss attacks render as proper `sigma_ball` / `sigma_lance` / `sigma_laser` sprites (currently colored rectangles).

### Stage rendering
- Replace `StageBackdrop` colored rectangles with the actual `Public/assets/stage/` artwork (whatever PNG exists there).

---

## P1 — Combat fidelity

- Charge shot: hold X to charge, release for `shot_strong` (100–102) tier. Mirrors `Charge.gd`.
- Variable-height jump tuning to match Godot frame timings.
- Knockback distance + i-frame duration matched to `Damage.gd`.
- Boss AI: port `BossAI.gd` priority/cooldown/desperation logic exactly (currently approximated).
- Sound effects (deferred — no audio assets currently in repo).

## P2 — HUD & polish

- HUD weapon icon + life bar pip animation matching the original `IGT.gd`/`IGScreen.gd` pattern.
- Intro cutscene: boss landing, pause, "BATTLE" splash.
- Victory / defeat sequences (boss explosion, X disappearing).

## P3 — Stretch

- Multiple bosses (would require new atlases).
- Pixel-accurate camera shake on boss landing / attacks.
- Frame-by-frame `SKAction.sequence` per Aseprite per-frame `duration` (vs. averaged).

---

## Verification — multiple-state screenshots

Browser-driven harness so a human (or this agent) can visually inspect every Player state without playing through the game manually.

1. **JS hook**: `main.swift` exposes `window.__megaman_test = { setPlayerState(state, opts), setPlayerFacing(dir), spawnBossAttack(name), pause(), resume() }`. Implementation calls into a `@MainActor` Swift function that mutates the live `Player`.
2. **State enum**: idle, walk, jump (rising), fall, dash, airdash, hurt, shot, turn, slide, walljump, victory.
3. **Capture loop**: a small `verify.html` page (or just devtools) cycles `Object.values(states)`, calls `__megaman_test.setPlayerState(s)`, waits ~150 ms for the animation to settle, then triggers a screenshot via the Chrome MCP `computer` tool.
4. **Output**: `verify/<state>.png` written next to the project. Visual diff is human-eyeballed for v1.

Acceptance for "Player implementation done":
- Each state in (1) renders with the correct sprite frames.
- `turn`, `airdash`, `walljump`, `wallslide` are reachable via normal input AND directly via the JS hook.
- All 12 screenshots show distinct, correct artwork.
