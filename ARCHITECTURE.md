# megaman — Architecture

This document describes the layered architecture of the megaman WASM application and the rules every contributor (human or LLM) must follow to keep that architecture intact. It complements `CLAUDE.md` (port-specific rules), `PORT_SCOPE.md` (gap analysis), and `REQUIREMENTS.md` (v1 scope).

> **Read this file before adding files, moving files, or wiring new dependencies.** When in doubt, the layer diagram is authoritative — code that violates the diagram is wrong even if it compiles.

---

## 1. Layered architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Entry / Bootstrap                                               │
│    Sources/WasmApp/main.swift                                    │
│    - URL routing  (?preview=player | battle | ?preview=boss)     │
│    - Scene construction                                          │
│    - JS bridge install (window.__megaman_test / __megaman_*)      │
└────────┬─────────────────────────────────────────────────────────┘
         │
   ┌─────┴───────────────────────────────────┐
   ▼                                         ▼
┌────────────────────────┐      ┌────────────────────────┐
│  Battle Scene          │      │  Preview Scene(s)      │
│   Scene/               │      │   Scene/               │
│    BossBattleScene     │      │    PlayerPreviewScene  │
│    Stage               │      │    (BossPreviewScene)  │
│    SigmaWall           │      │                        │
│    SigmaIntro          │      │                        │
│    (implements         │      │                        │
│     PlayerWorld +      │      │                        │
│     AttackContext via  │      │                        │
│     SceneAttackContext)│      │                        │
└────────┬───────────────┘      └────────┬───────────────┘
         │                               │
         └────────────┬──────────────────┘
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│  Actor Layer  (Actors/)                                          │
│    Actor (base, SKSpriteNode subclass)                           │
│      ├─ Player    (Action enum, state machine, physics)          │
│      │               talks back to Scene only via PlayerWorld    │
│      └─ Boss      (activeAttack, playAnimation, muzzlePos)       │
│    PlayerWorld  protocol seam (Scene-callback for Player)        │
└────────┬─────────────────────────────────────────────────────────┘
         │ Boss owns activeAttack
         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Attack Layer  (Attacks/)                                        │
│    protocol Attack + protocol AttackContext                      │
│      LanceThrow / GroundCombo / JumpCombo / AirCombo             │
│      OverdriveAttack                                             │
└────────┬───────────────────────────────▲─────────────────────────┘
         │ via AttackContext callbacks   │ instantiated by
         │ (no direct Scene/Boss imports)│ Systems/BossAI only
         ▼                               │
┌──────────────────────┐  ┌────────────────────┐  ┌──────────────────┐
│ Projectiles/         │  │ Graphics/          │  │ Systems/         │
│  Projectile          │  │  BossEffects       │  │  BossAI ─────────┤ (instantiates Attacks)
│  - sigmaLance        │  │  PlayerEffects     │  │  InputManager    │
│  - X buster          │  │  SpriteLoader      │  │  AudioManager    │
│  - dive bullets      │  │  SpriteAtlas       │  │  BossRNG         │
│  - air shots         │  │  AsepriteAtlas     │  │                  │
│                      │  │  EffectAtlasReg.   │  │                  │
└──────────────────────┘  └────────────────────┘  └──────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  HUD Layer  (HUD/)                                               │
│    HealthBar   WeaponBar   (GameOverFade lives in BossBattleScene)│
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Constants  (top-level)                                          │
│    GameConfig.swift — centralized numeric constants              │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Layer responsibilities

| Layer       | Directory       | Owns                                                                 | Must NOT                                                  |
|-------------|-----------------|----------------------------------------------------------------------|-----------------------------------------------------------|
| Entry       | `WasmApp/`      | URL routing, Scene boot, JS bridge install, run-loop wiring          | Hold game state. Implement gameplay logic.                |
| Scene       | `Scene/`        | Node hierarchy, per-frame tick orchestration, scene-state machine    | Implement actor physics. Define attack stages.            |
| Actor       | `Actors/`       | Per-actor state, physics body, animation playback, HP, death         | Reference Scene types directly. Know about Attacks.        |
| Attack      | `Attacks/`      | Boss attack state machines (one file per attack)                     | Reference Scene types. Hold Scene references.             |
| Projectiles | `Projectiles/`  | Self-propelling hitboxes + visuals                                    | Run AI. Decide spawn timing.                              |
| Graphics    | `Graphics/`     | Sprite/atlas loading, particle helpers, screenshake                  | Hold gameplay state. Decide when to spawn effects.        |
| Systems     | `Systems/`      | Cross-cutting singletons (input, audio, RNG, AI, intro sequence)     | Subclass scene-graph nodes (`SKNode` etc).                 |
| HUD         | `HUD/`          | Screen-space UI, fixed against the camera                            | Read engine internals. Mutate Actors/Attacks.             |
| Constants   | `GameConfig.swift` | Numeric tuning constants only                                     | Contain logic. Hold mutable state.                        |

---

## 3. Dependency rules

### 3.1 The arrows in the diagram are one-way

Each arrow is allowed; **the reverse direction is forbidden**.

| Allowed (top → bottom)                           | Forbidden (bottom → top)                         |
|--------------------------------------------------|--------------------------------------------------|
| `Scene` imports `Actor`                          | `Actor` imports `Scene` concrete types           |
| `Actor` calls `Scene` via `protocol PlayerWorld` | `Actor` references `BossBattleScene` directly    |
| `Actor` imports `Attack` protocol                | `Attack` imports `Actor` concrete types beyond `protocol AttackContext` |
| `Attack` calls `AttackContext` callbacks         | `Attack` references `BossBattleScene`            |
| `Scene` imports `HUD`                            | `HUD` imports `Scene` (or any actor)             |
| Anything imports `Systems` singletons            | `Systems` imports `Scene` / `Actor` concrete types |
| `Systems/BossAI` instantiates `Attack` types     | Other Systems modules instantiate `Attack` types |
| Anything imports `Graphics` helpers              | `Graphics` imports `Actor` / `Attack` / `Scene`  |
| Anything reads `GameConfig`                      | `GameConfig` imports anything                    |

**Rationale for the `BossAI → Attack` exception:** `Systems/BossAI` is the attack scheduler. It picks the next attack and constructs the concrete `Attack` instance, which it hands to `Boss` to own. No other Systems module may construct an `Attack`.

**Rationale for the `PlayerWorld` seam:** Player needs a couple of Scene-level operations (`sigmaWallContact(for:)`, `spawnPlayerShot(...)`). Instead of importing `BossBattleScene`, Player holds `weak var world: (any PlayerWorld)?` and Scene adopts the protocol. `PlayerPreviewScene` does not adopt it — `world == nil` short-circuits those branches.

### 3.2 Cross-layer communication uses protocol seams, not concrete imports

There are two canonical seams between gameplay layers and the Scene:

| Seam                          | Defined in              | Used by      | Implemented by         |
|-------------------------------|-------------------------|--------------|------------------------|
| `protocol AttackContext`      | `Attacks/Attack.swift`  | Attack layer | `BossBattleScene` (private `SceneAttackContext`) |
| `protocol PlayerWorld`        | `Actors/PlayerWorld.swift` | Player    | `BossBattleScene`      |

Neither seam should leak `BossBattleScene` to the caller. Attacks receive `boss`, `player`, arena bounds, and callbacks (`spawnProjectile`, `spawnEffect`, `emitDesperation`, `screenshake`). Player receives `sigmaWallContact(for:)`, `spawnPlayerShot(...)`.

When you add a new layer-crossing call:
1. Decide which side owns the call.
2. Add a method to the appropriate protocol (`AttackContext` or `PlayerWorld`).
3. Implement it on the concrete owner (`BossBattleScene`).
4. Never bypass the protocol with a direct `let scene = ... as! BossBattleScene`.

### 3.3 No circular dependencies

If you find yourself wanting to import "upward" (e.g. `Graphics` importing `Boss`), the design is wrong. Common fixes:

- Move the data the helper needs into a parameter.
- Extract a small protocol the upper layer can satisfy.
- Move the helper itself up a layer.

---

## 4. Adherence rules (DO / DON'T)

### 4.1 File placement

- **DO** place a new file in the layer that matches its responsibility — match the directory to the layer in §1.
- **DO** keep one primary type per file (`Player.swift` defines `Player`; supporting `enum Player.Action` is fine).
- **DON'T** add a file to `WasmApp/` root unless it is `main.swift` or a `GameConfig`-style constants module shared by all layers.
- **DON'T** create new top-level directories without first updating §1 of this document.

### 4.2 Imports

- **DO** keep every Attack file's imports limited to `Foundation` + `OpenSpriteKit` + the Attack/Actor protocols. If you need more, the design is wrong.
- **DON'T** import `BossBattleScene` from anywhere except `main.swift` and other `Scene/` files.
- **DON'T** import `OpenCoreGraphics` / `OpenCoreAnimation` / etc. directly. `OpenSpriteKit` re-exports them; importing them yourself causes ambiguity.

### 4.3 State ownership

- **DO** keep gameplay state inside Actor or Attack instances.
- **DO** keep cross-cutting state (input edge detection, RNG seed, audio mute) in a single Systems singleton.
- **DON'T** add module-level `var`s in `main.swift` for new gameplay state — extend the relevant Actor/Attack/System.
- **DON'T** store gameplay state on Graphics helpers. They are stateless utilities (a screenshake function is fine; a "current screenshake intensity" property is not).

### 4.4 JS bridge

There are two distinct interactions with JavaScript and they have different rules.

#### 4.4.a Test-hook installation

- **DO** install JS-callable closures (`window.__megaman_test`, `window.__megaman_preview`) **only** in `main.swift`. These are the test/debug surface for the page.
- **DO** capture Scene/Actor references via `[weak ...]` so the world isn't pinned across a scene swap.
- **DON'T** install or mutate `window.__megaman_*` from any other layer. The bridge is one direction: JS → Swift, set up at boot.

#### 4.4.b Web API consumption

- **DO** read `JSObject.global` for legitimate browser APIs (`document`, `fetch`, `Audio`, `performance`, `navigator`) **from the layer that owns that capability** — `Systems/InputManager` owns keyboard/gamepad, `Systems/AudioManager` owns audio, `Graphics/SpriteLoader` owns asset fetch.
- **DON'T** scatter `JSObject.global` access across Actor / Attack / HUD layers. If a new gameplay file needs a Web API, route it through (or extend) the appropriate Systems / Graphics module.

### 4.5 File size

- **Soft cap: 500 LOC per file.** When a file crosses 500 LOC, extract a sibling file in the same layer.
- **Hard cap: 1500 LOC per file.** Files currently in violation are tracked in §7 as refactor debt — do not let new files reach this size.
- Triggers for extraction (any one is enough):
  - A file owns more than one `enum`-driven state machine.
  - A file has more than ~12 distinct `private` helpers in a single section.
  - The same group of helpers is reused by another type in the same layer.

### 4.6 The Action / Stage idiom

| Actor  | Pattern                                                                                       | Rationale                                                                                         |
|--------|------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| Player | `enum Player.Action` — one case per Aseprite tag (idle, run, jump, …). Compound chains in JS. | Player has many short, addressable poses; users want to drive each one independently from preview.|
| Boss   | `protocol Attack` — one type per attack, internal `enum Stage` for the state machine.         | Boss attacks are multi-stage with hitboxes/projectiles; the unit is the attack, not the frame.    |

**DO** preserve this asymmetry. Player and Boss intentionally expose different granularities to the preview API and external code.

**DON'T** flatten Boss attacks into a giant `enum Boss.Action` — multi-stage state, hitbox lifecycle, and projectile spawning belong inside an Attack type.

### 4.7 Mock data and silent fallbacks (workspace-wide rule)

- **DO** fail loudly when an asset / atlas / texture is missing — log via `SKDiagnostics.logWarning` and let the visual be obviously broken so it is caught in review.
- **DON'T** fall back to a colored rectangle "until the real sprite loads". Per the workspace CLAUDE.md, visuals must come from the Aseprite sprite sheet; primitive stand-ins are forbidden.

---

## 5. Preview architecture

Preview scenes are **first-class peers of the battle scene**, not test hooks bolted on. They share the Actor / Attack / Graphics / Projectiles layers without modification.

```
main.swift
   ├─ ?preview=player → PlayerPreviewScene
   │     └─ Player (unchanged Actor, previewMode = true to short-circuit physics)
   │
   ├─ ?preview=boss   → BossPreviewScene  (proposed; not yet implemented)
   │     ├─ Boss   (unchanged)
   │     ├─ Attack layer (unchanged; AttackPreviewable extension for stage jumping)
   │     ├─ Projectiles (unchanged)
   │     └─ Graphics/BossEffects (unchanged)
   │
   └─ (default)       → BossBattleScene
```

### 5.1 Rules for preview scenes

- **DO** add new preview routes by adding a URL branch in `main.swift` and a `*PreviewScene.swift` in `Scene/`.
- **DO** expose preview controls under a dedicated JS namespace (`window.__megaman_preview` for the player, `window.__megaman_boss_preview` for the boss). Keep them disjoint from `__megaman_test` (which is for E2E battle assertions).
- **DON'T** add preview-only branches to Actor / Attack code paths beyond a single `previewMode: Bool` flag. Preview must use the production code paths; if it can't, the production code is too entangled with `BossBattleScene`.
- **DON'T** let preview state leak into battle. Preview scenes own a fresh Actor instance; they do not reuse the battle's Actor.

### 5.2 Preview granularity per actor

| Actor  | Preview unit                | Why                                                                                |
|--------|----------------------------|------------------------------------------------------------------------------------|
| Player | Single `Player.Action` pose | Player exposes 1 tag = 1 pose; compound chains live in HTML/JS, not Swift.         |
| Boss   | Single `Attack` instance    | Attacks are the smallest meaningful unit; sub-stage debug surface is secondary.    |

---

## 6. How to add a new feature (cookbook)

### 6.1 New boss attack

1. Read the upstream Godot scripts and `.tscn` end to end (see `CLAUDE.md` § "Output a full Godot specification report BEFORE writing any port code").
2. Add `Attacks/<Name>.swift` implementing `protocol Attack`, with a private `enum Stage` for the state machine. **Use `Attacks/LanceThrow.swift` as the canonical reference** — it shows the full pattern: stage enum, hitbox lifecycle, projectile spawning, screenshake calls, and `isFinished` semantics.
3. If the attack needs new context (e.g. ceiling Y), add it to `protocol AttackContext`, implement on `BossBattleScene`'s private `SceneAttackContext`, and only then use it in the new attack.
4. Add the `AttackKind` case in `Systems/BossAI.swift` and wire `forceAttack` if it should be reachable from E2E tests.
5. Add a `Projectiles/` entry only if the attack spawns a self-propelling hitbox; otherwise use `BossEffects` for pure visuals.
6. Mirror frame-tag and timing data exactly from the Aseprite atlas.

### 6.2 New player ability

1. Add the case to `Player.Action` if it has a distinct Aseprite tag.
2. Implement state-machine transitions inside `Player.swift` next to existing transitions (e.g. dash, walljump). Do not create a sibling `PlayerAbilities.swift` unless the file crosses §4.5 thresholds.
3. Cross-reference Godot constants from `Mega-Man-X8-16-bit/src/Actors/Abilities/` and put numeric tunings in `GameConfig.swift`.

### 6.3 New visual effect

1. If it is generic (particles, screenshake, hit flash) → extend `Graphics/BossEffects` or `Graphics/PlayerEffects`.
2. If it is attack-specific → keep it inside the Attack file as a `private func`.
3. Sprites/atlases come from the Aseprite source; load via `SpriteLoader`. No primitive fallbacks (workspace rule).

### 6.4 New JS test hook

1. Add the closure in `main.swift` under `__megaman_test` (battle) or the appropriate `__megaman_*_preview` namespace.
2. Capture references with `[weak]` to avoid retaining old scenes after a navigation.
3. The Swift implementation lives in the relevant Actor / Attack / Scene — the closure in `main.swift` is a thin adapter only.

---

## 7. Known violations (refactor debt)

These exist today and are tracked here so new work does not amplify them:

| File                                  | LOC   | Issue                                                                                                | Proposed split                                                                                                                                          |
|---------------------------------------|-------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Actors/Player.swift`                 | 2205  | Hard-cap (1500) violation. One file owns idle/walk/run/dash/jump/airDash/wallSlide/wallJump/hurt/death/charge/shoot/intro-beam state machines | Split into: `Player.swift` (state-machine core, ~600), `Player+Movement.swift` (dash/jump/wallSlide/wallJump), `Player+Combat.swift` (shoot/charge/hurt/death), `Player+Beam.swift` (intro beam / beam_in / armor_receive). Extensions only — no behavioural change. |
| `Scene/BossBattleScene.swift`         | 1012  | Soft-cap (500) over 2×. Mixes scene composition, fade overlay, win/lose flow, HUD wiring             | Extract fade-overlay + game-over flow into a sibling `Scene/GameOverFade.swift`; HUD-wiring into `Scene/BossBattleScene+HUD.swift`.                      |
| `Sources/WasmApp/main.swift`          | 1368  | Soft-cap over 2×. Inlines scene management + ~30 JS-test closures                                    | Acceptable while URL routes ≤ 3. At 4+, extract a `SceneRouter` and split `__megaman_test` closures into `WasmApp/Bridge/TestHarness.swift`.            |
| `Graphics/BossEffects.swift`          | 610   | Soft-cap exceeded. Mixes wall-pillar particles, sigma-laser overlays, lance-trail attachment, screenshake helpers | Split per attack family: `BossEffects+Wall.swift`, `BossEffects+Lance.swift`, `BossEffects+Laser.swift`, keeping shared screenshake in the core file. |

**DO NOT** copy these patterns into new files. They are debt, not templates. Implementation of the splits is tracked separately — when adding new code, choose the future filename and **place new code in a sibling file from day one** rather than appending to the violator.

---

## 8. Authoritative sources

When this document and the code disagree:

- For layer membership / file placement → **the directory layout in §1 wins**, and this document must be updated to reflect any intentional new layer.
- For dependency direction → **the diagram in §1 wins**.
- For Godot porting fidelity → **the Godot upstream wins** (per `CLAUDE.md`).
- For numeric tuning → **`GameConfig.swift` is the single source**, not scattered literals.

If you cannot fit a change into the rules above, stop and propose an architecture amendment — do not work around the rules silently.
