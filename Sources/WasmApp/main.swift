// megaman - Mega Man X8 boss battle port onto OpenSpriteKit (WASM).
// The entry point wires up the canvas, SKRenderer, input and the BossBattleScene.

import Foundation
import JavaScriptKit
import JavaScriptEventLoop
import OpenSpriteKit

// MARK: - Canvas configuration

enum CanvasConfig {
    nonisolated(unsafe) static var width: Int = GameConfig.gameWidth
    nonisolated(unsafe) static var height: Int = GameConfig.gameHeight
}

// MARK: - Global state

nonisolated(unsafe) var renderer: SKRenderer?
nonisolated(unsafe) var battleScene: BossBattleScene?
nonisolated(unsafe) var startTime: Double = 0
nonisolated(unsafe) var animationCallback: JSClosure?
nonisolated(unsafe) var frameCount: Int = 0
nonisolated(unsafe) var setupClosures: [JSClosure] = []
// Test harness manual-stepping state. When `stepMode` is true the rAF
// callback stops re-scheduling and `step()` becomes the sole update driver —
// this lets Playwright advance the simulation deterministically even when the
// browser tab is hidden (rAF is throttled to 0 Hz by Chromium in that case,
// which is why frameCount stayed at 0 during background-tab tests).
nonisolated(unsafe) var stepMode: Bool = false
nonisolated(unsafe) var virtualSimTime: TimeInterval = -1

// MARK: - WASM exports

@_cdecl("getCanvasWidth")
public func getCanvasWidth() -> Int32 {
    return Int32(CanvasConfig.width)
}

@_cdecl("getCanvasHeight")
public func getCanvasHeight() -> Int32 {
    return Int32(CanvasConfig.height)
}

@_cdecl("setup")
public func setup() {
    print("megaman boss battle — booting OpenSpriteKit…")
    JavaScriptEventLoop.installGlobalExecutor()
    let startSetup = JSClosure { _ -> JSValue in
        print("megaman boss battle — starting async setup")
        Task { await performSetup() }
        return .undefined
    }
    setupClosures = [startSetup]
    _ = JSObject.global.setTimeout!(startSetup, 0)
}

// MARK: - Setup

@MainActor
func performSetup() async {
    let document = JSObject.global.document
    let canvasValue = document.getElementById("canvas")
    guard let canvasElement = canvasValue.object else {
        print("Canvas element not found")
        return
    }

    // Render at native game resolution for pixel-perfect output; CSS scales the element.
    CanvasConfig.width = GameConfig.gameWidth
    CanvasConfig.height = GameConfig.gameHeight
    applyPixelArtCanvasCSS(canvas: canvasElement)

    // Attach input listeners (held + edge-triggered keyboard state).
    InputManager.shared.setup()

    // Build the boss battle scene at the native resolution.
    let scene = BossBattleScene(stage: .bossArena)
    scene.scaleMode = .fill
    battleScene = scene

    let skRenderer: SKRenderer
    #if arch(wasm32)
    skRenderer = SKRenderer(canvas: canvasElement)
    #else
    skRenderer = SKRenderer()
    #endif
    do {
        try await skRenderer.initialize()
        skRenderer.resize(width: CanvasConfig.width, height: CanvasConfig.height)
    } catch {
        print("Failed to initialize SKRenderer: \(error)")
        return
    }

    skRenderer.scene = scene
    renderer = skRenderer

    // SKScene.didMove(to:) is invoked by the renderer when the scene is presented,
    // but SKRenderer uses the raw scene tree — call it explicitly so the scene can build.
    let skView = SKView()
    scene.didMove(to: skView)

    startTime = JSObject.global.performance.now().number ?? 0
    print("Boss battle ready — \(CanvasConfig.width)x\(CanvasConfig.height)")
    startAnimationLoop()

    // Load sprite atlases off the dev server. Done after the loop starts so the
    // user sees the placeholder sprite immediately and the textures swap in
    // when fetch + decode completes.
    Task { await loadSpriteAtlases() }

    installTestHarness()
}

@MainActor
func loadSpriteAtlases() async {
    guard let scene = battleScene else { return }

    // Fetch every atlas in parallel — on slow connections this halves wall
    // time vs. the sequential path and nothing depends on order.
    async let playerLoad = SpriteLoader.load(group: "player", name: "x")
    async let bossLoad   = SpriteLoader.load(group: "boss", name: "satan_sigma")
    async let ballLoad   = SpriteLoader.load(group: "boss", name: "sigma_ball")
    async let lanceLoad  = SpriteLoader.load(group: "boss", name: "sigma_lance")
    async let laserLoad  = SpriteLoader.load(group: "boss", name: "sigma_laser")
    async let lemonLoad  = SpriteLoader.load(group: "projectiles", name: "lemon")
    async let mediumLoad = SpriteLoader.load(group: "projectiles", name: "medium_shot")
    async let heavyLoad  = SpriteLoader.load(group: "projectiles", name: "heavy_shot")
    async let charge1Load = SpriteLoader.load(group: "effects", name: "charge_1")
    async let charge2Load = SpriteLoader.load(group: "effects", name: "charge_2")

    do {
        let atlas = try await playerLoad
        scene.attachPlayerAtlas(atlas)
        print("player/x loaded — \(atlas.animations.count) tags")
    } catch {
        print("player/x failed: \(error)")
    }
    do {
        let atlas = try await bossLoad
        scene.attachBossAtlas(atlas)
        print("boss/satan_sigma loaded — \(atlas.animations.count) tags")
    } catch {
        print("boss/satan_sigma failed: \(error)")
    }
    do {
        let atlas = try await ballLoad
        scene.attachProjectileAtlas(atlas, for: .sigmaBall)
        print("boss/sigma_ball loaded — \(atlas.animations.count) tags")
    } catch {
        print("boss/sigma_ball failed: \(error)")
    }
    do {
        let atlas = try await lanceLoad
        scene.attachProjectileAtlas(atlas, for: .sigmaLance)
        print("boss/sigma_lance loaded — \(atlas.animations.count) tags")
    } catch {
        print("boss/sigma_lance failed: \(error)")
    }
    do {
        let atlas = try await laserLoad
        scene.attachProjectileAtlas(atlas, for: .sigmaLaser)
        print("boss/sigma_laser loaded — \(atlas.animations.count) tags")
    } catch {
        print("boss/sigma_laser failed: \(error)")
    }
    do {
        let atlas = try await lemonLoad
        scene.attachProjectileAtlas(atlas, for: .lemon)
        print("projectiles/lemon loaded — \(atlas.animations.count) tags")
    } catch {
        print("projectiles/lemon failed: \(error)")
    }
    do {
        let atlas = try await mediumLoad
        scene.attachProjectileAtlas(atlas, for: .mediumBuster)
        print("projectiles/medium_shot loaded — \(atlas.animations.count) tags")
    } catch {
        print("projectiles/medium_shot failed: \(error)")
    }
    do {
        let atlas = try await heavyLoad
        scene.attachProjectileAtlas(atlas, for: .chargedBuster)
        print("projectiles/heavy_shot loaded — \(atlas.animations.count) tags")
    } catch {
        print("projectiles/heavy_shot failed: \(error)")
    }
    do {
        let atlas = try await charge1Load
        scene.attachChargeAtlas(atlas, for: 1)
        print("effects/charge_1 loaded — \(atlas.animations.count) tags")
    } catch {
        print("effects/charge_1 failed: \(error)")
    }
    do {
        let atlas = try await charge2Load
        scene.attachChargeAtlas(atlas, for: 2)
        print("effects/charge_2 loaded — \(atlas.animations.count) tags")
    } catch {
        print("effects/charge_2 failed: \(error)")
    }

    // Godot effect PNGs ship without an Aseprite JSON sidecar; the Godot
    // `ParticleProcessMaterial` + `TextureAtlas` H/V frame counts drive the
    // grid layout. Load sequentially — running these as additional `async let`
    // alongside the 10 authored atlases above starves the JavaScriptKit
    // fetch promise queue on WASM and the awaits never resume.
    await loadGridAtlas(name: "sparks",            cols: 3, rows: 2, frameDurationMs: 60,  kind: .sparks)
    await loadGridAtlas(name: "circle",            cols: 1, rows: 1,                       kind: .circle)
    await loadGridAtlas(name: "dash",              cols: 3, rows: 2, frameDurationMs: 60,  kind: .dash)
    await loadGridAtlas(name: "smoke",             cols: 3, rows: 3, frameDurationMs: 60,  kind: .smoke)
    await loadGridAtlas(name: "airdash",           cols: 3, rows: 2, frameDurationMs: 60,  kind: .airdash)
    await loadGridAtlas(name: "death",             cols: 3, rows: 2, frameDurationMs: 140, kind: .death)
    await loadGridAtlas(name: "light",             cols: 1, rows: 1,                       kind: .light)
    // Lance.tscn overlays — trail (9-frame stack), evilfire (1×1 puff),
    // firetip (3×3 anim atlas, lifetime 0.5s ÷ 9 frames ≈ 56ms).
    await loadGridAtlas(name: "sigma_trail",       cols: 1, rows: 9, frameDurationMs: 33,  kind: .sigmaTrail)
    await loadGridAtlas(name: "sigma_particles",   cols: 1, rows: 1,                       kind: .sigmaParticle)
    await loadGridAtlas(name: "sigma_particles2",  cols: 3, rows: 3, frameDurationMs: 56,  kind: .sigmaParticleAnim)
}

@MainActor
private func loadGridAtlas(
    name: String,
    cols: Int,
    rows: Int,
    frameDurationMs: Int = 100,
    kind: EffectAtlases.Kind
) async {
    do {
        let atlas = try await SpriteLoader.loadGrid(
            group: "effects",
            name: name,
            cols: cols,
            rows: rows,
            frameDurationMs: frameDurationMs
        )
        EffectAtlases.register(atlas, for: kind)
        print("effects/\(name) loaded — grid \(cols)x\(rows)")
    } catch {
        print("effects/\(name) failed: \(error)")
    }
}

// MARK: - Test harness (window.__megaman_test)

@MainActor
func installTestHarness() {
    let harness = JSObject.global.Object.function!.new()

    let setState = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene,
                  let raw = args.first?.string,
                  let state = PlayerState(rawValue: raw) else { return }
            let facing: Facing? = args.count > 1 ? facingFrom(args[1].string) : nil
            scene.isPaused = true
            scene.player.debugForce(state: state, facing: facing)
        }
        return .undefined
    }
    let release = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene else { return }
            scene.isPaused = false
            scene.player.debugRelease()
        }
        return .undefined
    }
    let pause = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated { battleScene?.isPaused = true }
        return .undefined
    }
    let resume = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated { battleScene?.isPaused = false }
        return .undefined
    }
    let listStates = JSClosure { _ -> JSValue in
        let names = PlayerState.allCases.map { $0.rawValue }
        return JSValue.object(JSObject.global.Array.function!.new(names))
    }
    let getInfo = JSClosure { _ -> JSValue in
        let snapshot: (x: Double, y: Double, vx: Double, vy: Double, state: String, facing: String, onFloor: Bool)? =
            MainActor.assumeIsolated {
                guard let scene = battleScene else { return nil }
                let p = scene.player
                return (
                    Double(p.position.x),
                    Double(p.position.y),
                    Double(p.velocity.dx),
                    Double(p.velocity.dy),
                    p.state.rawValue,
                    p.facing == .left ? "left" : "right",
                    p.onFloor
                )
            }
        guard let s = snapshot else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.x = .number(s.x)
        obj.y = .number(s.y)
        obj.vx = .number(s.vx)
        obj.vy = .number(s.vy)
        obj.state = .string(s.state)
        obj.facing = .string(s.facing)
        obj.onFloor = .boolean(s.onFloor)
        return .object(obj)
    }
    let getFrameCount = JSClosure { _ -> JSValue in
        .number(Double(frameCount))
    }
    let getBossInfo = JSClosure { _ -> JSValue in
        let snapshot: (x: Double, y: Double, vx: Double, vy: Double, hp: Double, attack: String, projCount: Double, facing: String, bossXScale: Double, visualXScale: Double)? =
            MainActor.assumeIsolated {
                guard let scene = battleScene else { return nil }
                let b = scene.boss
                let attackName = b.activeAttack.map { String(describing: type(of: $0)) } ?? "none"
                let visualXScale: Double = b.children.first.map { Double($0.xScale) } ?? .nan
                return (
                    Double(b.position.x),
                    Double(b.position.y),
                    Double(b.velocity.dx),
                    Double(b.velocity.dy),
                    Double(b.currentHealth),
                    attackName,
                    Double(scene.liveProjectileCount),
                    b.facing == .left ? "left" : "right",
                    Double(b.xScale),
                    visualXScale
                )
            }
        guard let s = snapshot else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.x = .number(s.x); obj.y = .number(s.y)
        obj.vx = .number(s.vx); obj.vy = .number(s.vy)
        obj.hp = .number(s.hp)
        obj.attack = .string(s.attack)
        obj.projCount = .number(s.projCount)
        obj.facing = .string(s.facing)
        obj.bossXScale = .number(s.bossXScale)
        obj.visualXScale = .number(s.visualXScale)
        return .object(obj)
    }

    let setPlayerPosition = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene else { return }
            if let x = args.first?.number {
                scene.player.position.x = CGFloat(x)
            }
            if args.count > 1, let y = args[1].number {
                scene.player.position.y = CGFloat(y)
            }
            scene.player.onFloor = scene.player.position.y <= GameConfig.floorY
            scene.player.velocity = .zero
        }
        return .undefined
    }

    let damageBoss = JSClosure { args -> JSValue in
        let result: (applied: Bool, hp: Double)? = MainActor.assumeIsolated {
            guard let scene = battleScene else { return nil }
            let amount = CGFloat(args.first?.number ?? 1)
            let applied = scene.boss.takeDamage(amount)
            return (applied, Double(scene.boss.currentHealth))
        }
        guard let result else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.applied = .boolean(result.applied)
        obj.hp = .number(result.hp)
        return .object(obj)
    }

    let getAIState = JSClosure { _ -> JSValue in
        let snap: (active: Bool, timer: Double, cooldown: Double, cursor: Double, orderCount: Double, phase: String)? =
            MainActor.assumeIsolated {
                guard let scene = battleScene, let ai = scene.bossAI else { return nil }
                let phase: String
                switch scene.phase {
                case .intro: phase = "intro"
                case .fighting: phase = "fighting"
                case .victory: phase = "victory"
                case .defeat: phase = "defeat"
                case .gameOver: phase = "gameOver"
                }
                return (
                    ai.isActive,
                    Double(ai.timer),
                    Double(ai.cooldown),
                    Double(ai.cursor),
                    Double(ai.orderCount),
                    phase
                )
            }
        guard let s = snap else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.active = .boolean(s.active)
        obj.timer = .number(s.timer)
        obj.cooldown = .number(s.cooldown)
        obj.cursor = .number(s.cursor)
        obj.orderCount = .number(s.orderCount)
        obj.phase = .string(s.phase)
        return .object(obj)
    }

    let getPerfStats = JSClosure { _ -> JSValue in
        let snapshot: (
            frameCount: Double,
            fps: Double,
            phase: String,
            sceneChildren: Double,
            totalProjectiles: Double,
            liveProjectiles: Double,
            deadProjectiles: Double,
            playerProjectiles: Double,
            bossProjectiles: Double,
            diagnostics: SKDiagnosticsSnapshot
        )? = MainActor.assumeIsolated {
            guard let scene = battleScene else { return nil }
            return (
                Double(frameCount),
                scene.currentFPS,
                scene.phaseName,
                Double(scene.children.count),
                Double(scene.totalProjectileCount),
                Double(scene.liveProjectileCount),
                Double(scene.deadProjectileCount),
                Double(scene.playerProjectileCount),
                Double(scene.bossProjectileCount),
                SKDiagnostics.shared.snapshot(scene: scene)
            )
        }
        guard let s = snapshot else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.frameCount = .number(s.frameCount)
        obj.fps = .number(s.fps)
        obj.phase = .string(s.phase)
        obj.sceneChildren = .number(s.sceneChildren)
        obj.totalProjectiles = .number(s.totalProjectiles)
        obj.liveProjectiles = .number(s.liveProjectiles)
        obj.deadProjectiles = .number(s.deadProjectiles)
        obj.playerProjectiles = .number(s.playerProjectiles)
        obj.bossProjectiles = .number(s.bossProjectiles)
        obj.totalNodes = .number(Double(s.diagnostics.nodeCount))
        obj.emitters = .number(Double(s.diagnostics.emitterCount))
        obj.particles = .number(Double(s.diagnostics.particleCount))
        obj.runningActions = .number(Double(s.diagnostics.runningActionCount))
        obj.actionNodeBuckets = .number(Double(s.diagnostics.actionNodeBucketCount))
        obj.orphanedActionNodeBuckets = .number(Double(s.diagnostics.orphanedActionNodeBucketCount))
        obj.textures = .number(Double(s.diagnostics.textureCount))
        obj.gpuTextures = .number(Double(s.diagnostics.gpuTextureCount))

        obj.resources = .string(s.diagnostics.resourceCounts)

        if let memory = JSObject.global.performance.memory.object {
            obj.jsHeapUsedBytes = .number(memory.usedJSHeapSize.number ?? 0)
            obj.jsHeapTotalBytes = .number(memory.totalJSHeapSize.number ?? 0)
            obj.jsHeapLimitBytes = .number(memory.jsHeapSizeLimit.number ?? 0)
        }
        return .object(obj)
    }

    let disableBoss = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene, let ai = scene.bossAI else { return }
            ai.deactivate()
            scene.clearBossProjectiles()
        }
        return .undefined
    }

    // Test-only: trigger a specific attack by name. Accepts:
    // "groundCombo", "jumpCombo", "lanceThrow", "airCombo", "overdrive".
    let forceAttack = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene, let ai = scene.bossAI, let name = args.first?.string else { return }
            if name == "overdrive" {
                ai.forceDesperation()
                return
            }
            let kind: BossAI.AttackKind?
            switch name {
            case "groundCombo": kind = .groundCombo
            case "jumpCombo":   kind = .jumpCombo
            case "lanceThrow":  kind = .lanceThrow
            case "airCombo":    kind = .airCombo
            default: kind = nil
            }
            if let kind { ai.forceAttack(kind) }
        }
        return .undefined
    }

    // Lethal takeDamage on the Player — exercises the natural `die()` path so
    // `tickDeathSequence` drives the death explosion on subsequent frames.
    // Used by `death_explosion.spec.ts` to assert sparkle animation without
    // waiting ~15 s for Sigma contact damage.
    let killPlayer = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene else { return }
            scene.player.debugKill()
        }
        return .undefined
    }

    // Drive InputManager from JS without dispatching DOM keyboard events.
    // Mirrors page.keyboard.down/up but routes through the same code path the
    // browser uses, so edge triggers (jumpPressed, dashPressed) fire on the
    // next frame just like real input.
    //   pressKey("ArrowRight", true) / pressKey("Space", false)
    let pressKey = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let key = args.first?.string else { return }
            let down = args.count > 1 ? (args[1].boolean ?? true) : true
            InputManager.shared.setKey(key, down: down)
        }
        return .undefined
    }

    // Release every held key + every edge state in one call. Useful between
    // capture scenarios so a leftover ArrowRight from the previous run doesn't
    // leak into the next.
    let releaseKeys = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated { InputManager.shared.clearAllKeys() }
        return .undefined
    }

    // High-level player action shortcut. Unlike `setState` (which freezes the
    // player into a static visual pose for screenshots), this drives the
    // natural input pipeline so the FSM advances normally.
    //
    //   forcePlayerAction("dash")          // tap dash 250ms
    //   forcePlayerAction("jump")          // tap jump 250ms (extended jump)
    //   forcePlayerAction("shoot")         // tap shoot 50ms (lemon)
    //   forcePlayerAction("walkRight")     // hold right indefinitely (use stop)
    //   forcePlayerAction("walkLeft")      // hold left indefinitely
    //   forcePlayerAction("dashRight")     // hold right + tap dash
    //   forcePlayerAction("hurt")          // takeDamage(8) → enters .hurt state
    //   forcePlayerAction("stop")          // releaseKeys equivalent
    //
    // Background timers keep firing even after the closure returns, so a
    // tapped key naturally releases ~250ms later without the caller having
    // to schedule the up event.
    let forcePlayerAction = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene, let name = args.first?.string else { return }
            let im = InputManager.shared
            switch name {
            case "stop":
                im.clearAllKeys()
            case "walkRight":
                im.setKey("ArrowRight", down: true)
            case "walkLeft":
                im.setKey("ArrowLeft", down: true)
            case "shoot":
                im.setKey("x", down: true)
                _ = JSObject.global.setTimeout!(JSClosure { _ in
                    MainActor.assumeIsolated { InputManager.shared.setKey("x", down: false) }
                    return .undefined
                }, 50)
            case "shootCharged":
                // Hold shoot long enough to reach charge level 2 (~0.85s in Godot Charge.gd).
                im.setKey("x", down: true)
                _ = JSObject.global.setTimeout!(JSClosure { _ in
                    MainActor.assumeIsolated { InputManager.shared.setKey("x", down: false) }
                    return .undefined
                }, 1100)
            case "jump":
                im.setKey(" ", down: true)
                _ = JSObject.global.setTimeout!(JSClosure { _ in
                    MainActor.assumeIsolated { InputManager.shared.setKey(" ", down: false) }
                    return .undefined
                }, 250)
            case "dash":
                im.setKey("c", down: true)
                _ = JSObject.global.setTimeout!(JSClosure { _ in
                    MainActor.assumeIsolated { InputManager.shared.setKey("c", down: false) }
                    return .undefined
                }, 250)
            case "dashRight":
                im.setKey("ArrowRight", down: true)
                im.setKey("c", down: true)
                _ = JSObject.global.setTimeout!(JSClosure { _ in
                    MainActor.assumeIsolated { InputManager.shared.setKey("c", down: false) }
                    return .undefined
                }, 250)
            case "dashLeft":
                im.setKey("ArrowLeft", down: true)
                im.setKey("c", down: true)
                _ = JSObject.global.setTimeout!(JSClosure { _ in
                    MainActor.assumeIsolated { InputManager.shared.setKey("c", down: false) }
                    return .undefined
                }, 250)
            case "hurt":
                _ = scene.player.takeDamage(8, inflicterX: scene.boss.position.x)
            default:
                break
            }
        }
        return .undefined
    }

    // Manually advance the simulation by `dtMs` milliseconds, calling both
    // update() and render(). Implicitly enters stepMode (stops rAF) so the
    // virtual clock and the wall clock can't drift out of sync.
    //
    // Usage from JS: `__megaman_test.step(16.67)` advances one 60-Hz frame.
    //                `__megaman_test.step(100, 6)` advances 6× 100ms frames.
    let step = JSClosure { args -> JSValue in
        let dtMs: Double = args.first?.number ?? (1000.0 / 60.0)
        let frames: Int
        if args.count > 1, let n = args[1].number {
            frames = max(1, Int(n))
        } else {
            frames = 1
        }
        MainActor.assumeIsolated {
            guard let skRenderer = renderer else { return }
            let firstEntry = !stepMode
            stepMode = true
            if virtualSimTime < 0 {
                // Seed from wall-clock so actions that were already running
                // under rAF don't see a time discontinuity.
                let now = JSObject.global.performance.now().number ?? 0
                virtualSimTime = (now - startTime) / 1000.0
            }
            if firstEntry {
                // The renderer's `lastUpdateTime` was last set by rAF against
                // the wall-clock. If rAF has been throttled (tab hidden) the
                // first internal dt would be enormous and every running
                // SKAction would jump to completion on one tick. Clear it so
                // the priming call below seeds the timeline afresh.
                skRenderer.resetTimeline()
                battleScene?.resetTimeline()
                skRenderer.update(atTime: virtualSimTime)  // dt = 0 (baseline)
            }
            let dt = dtMs / 1000.0
            for _ in 0..<frames {
                virtualSimTime += dt
                skRenderer.update(atTime: virtualSimTime)
                skRenderer.render()
                frameCount &+= 1
            }
        }
        return .undefined
    }

    // Re-enable the rAF-driven loop. Note: does NOT kick rAF itself — it only
    // clears the stepMode flag. The next rAF callback (if one is scheduled)
    // will start updating again. If rAF has fully stopped (tab hidden, no
    // pending callback), user must bring the tab to front OR call step().
    let resumeRAF = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated {
            stepMode = false
            virtualSimTime = -1
            // Same rationale as `step` first-entry: the virtual clock's last
            // update sits far from the wall-clock rAF is about to pass in.
            // Reset so the first rAF-driven frame produces a normal dt.
            renderer?.resetTimeline()
            battleScene?.resetTimeline()
            // Re-arm rAF so it picks back up even if it had no pending
            // callback (e.g. returning from a test that left stepMode on).
            if let cb = animationCallback {
                _ = JSObject.global.requestAnimationFrame!(cb)
            }
        }
        return .undefined
    }

    // Diagnostic: reports scene child count + visible-sprite details so tests
    // can verify death-burst spawn without pixel readback (WebGPU swap-chain
    // is opaque to Canvas2D `drawImage`).
    struct NodeSnapshot: Sendable {
        let name: String
        let x: Double
        let y: Double
        let z: Double
        let xScale: Double
        let yScale: Double
        let alpha: Double
        let hidden: Bool
        let paused: Bool
        let speed: Double
        let childCount: Int
        let spriteW: Double?
        let spriteH: Double?
        let hasTexture: Bool?
        let layerHasContents: Bool
        let layerMasksToBounds: Bool
        let layerBoundsW: Double
        let layerBoundsH: Double
        let layerOpacity: Double
        let layerHidden: Bool
        let children: [NodeSnapshot]
    }
    @MainActor func snapshotNode(_ node: SKNode, depth: Int) -> NodeSnapshot {
        var childSnaps: [NodeSnapshot] = []
        if depth > 0 {
            childSnaps = node.children.map { snapshotNode($0, depth: depth - 1) }
        }
        var spriteW: Double? = nil
        var spriteH: Double? = nil
        var hasTex: Bool? = nil
        if let sprite = node as? SKSpriteNode {
            spriteW = Double(sprite.size.width)
            spriteH = Double(sprite.size.height)
            hasTex = sprite.texture != nil
        }
        return NodeSnapshot(
            name: String(describing: type(of: node)),
            x: Double(node.position.x),
            y: Double(node.position.y),
            z: Double(node.zPosition),
            xScale: Double(node.xScale),
            yScale: Double(node.yScale),
            alpha: Double(node.alpha),
            hidden: node.isHidden,
            paused: node.isPaused,
            speed: Double(node.speed),
            childCount: node.children.count,
            spriteW: spriteW,
            spriteH: spriteH,
            hasTexture: hasTex,
            layerHasContents: node.layer.contents != nil,
            layerMasksToBounds: node.layer.masksToBounds,
            layerBoundsW: Double(node.layer.bounds.width),
            layerBoundsH: Double(node.layer.bounds.height),
            layerOpacity: Double(node.layer.opacity),
            layerHidden: node.layer.isHidden,
            children: childSnaps
        )
    }
    func snapshotToJS(_ s: NodeSnapshot) -> JSObject {
        let obj = JSObject.global.Object.function!.new()
        obj.name = .string(s.name)
        obj.x = .number(s.x)
        obj.y = .number(s.y)
        obj.z = .number(s.z)
        obj.xScale = .number(s.xScale)
        obj.yScale = .number(s.yScale)
        obj.alpha = .number(s.alpha)
        obj.hidden = .boolean(s.hidden)
        obj.paused = .boolean(s.paused)
        obj.speed = .number(s.speed)
        obj.childCount = .number(Double(s.childCount))
        if let w = s.spriteW { obj.spriteW = .number(w) }
        if let h = s.spriteH { obj.spriteH = .number(h) }
        if let t = s.hasTexture { obj.hasTexture = .boolean(t) }
        obj.layerHasContents = .boolean(s.layerHasContents)
        obj.layerMasksToBounds = .boolean(s.layerMasksToBounds)
        obj.layerBoundsW = .number(s.layerBoundsW)
        obj.layerBoundsH = .number(s.layerBoundsH)
        obj.layerOpacity = .number(s.layerOpacity)
        obj.layerHidden = .boolean(s.layerHidden)
        if !s.children.isEmpty {
            let childArr = JSObject.global.Array.function!.new()
            for (i, c) in s.children.enumerated() {
                childArr[i] = .object(snapshotToJS(c))
            }
            obj.children = .object(childArr)
        }
        return obj
    }

    let getSceneChildren = JSClosure { args -> JSValue in
        let depth: Int
        if let first = args.first, let n = first.number {
            depth = Int(n)
        } else {
            depth = 0
        }
        let snapshots: [NodeSnapshot] = MainActor.assumeIsolated {
            guard let scene = battleScene else { return [] }
            return scene.children.map { snapshotNode($0, depth: depth) }
        }
        let arr = JSObject.global.Array.function!.new()
        for (i, s) in snapshots.enumerated() {
            arr[i] = .object(snapshotToJS(s))
        }
        return .object(arr)
    }

    // MARK: - Debug helpers (added late so the harness can use them)

    // Teleport the boss. `args[0]=x, args[1]=y, args[2]=facing("left"|"right")`.
    // Clears velocity so the boss doesn't continue any prior movement on the
    // next physics tick. Useful for placing Sigma at a known coordinate before
    // triggering an attack.
    let setBossPosition = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene else { return }
            if let x = args.first?.number {
                scene.boss.position.x = CGFloat(x)
            }
            if args.count > 1, let y = args[1].number {
                scene.boss.position.y = CGFloat(y)
            }
            if args.count > 2, let f = facingFrom(args[2].string) {
                scene.boss.face(f)
            }
            scene.boss.velocity = .zero
        }
        return .undefined
    }

    let setBossFacing = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene else { return }
            if let f = facingFrom(args.first?.string) {
                scene.boss.face(f)
            }
        }
        return .undefined
    }

    let setBossHealth = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene, let v = args.first?.number else { return }
            scene.boss.debugSetHealth(CGFloat(v))
        }
        return .undefined
    }

    let setPlayerHealth = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene, let v = args.first?.number else { return }
            scene.player.debugSetHealth(CGFloat(v))
        }
        return .undefined
    }

    // Computed cannon mouth in world coords — used to verify the laser anchor
    // sits on the rendered cannon arm. Returns null if no scene yet.
    let getBossMuzzle = JSClosure { _ -> JSValue in
        let pt: (x: Double, y: Double)? = MainActor.assumeIsolated {
            guard let scene = battleScene else { return nil }
            let m = scene.boss.muzzlePosition
            return (Double(m.x), Double(m.y))
        }
        guard let p = pt else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.x = .number(p.x)
        obj.y = .number(p.y)
        return .object(obj)
    }

    // Snapshot all projectiles — kind, world-space rect, velocity, alive flag.
    let getProjectiles = JSClosure { _ -> JSValue in
        let snaps: [BossBattleScene.ProjectileSnapshot] = MainActor.assumeIsolated {
            battleScene?.projectileSnapshots() ?? []
        }
        let arr = JSObject.global.Array.function!.new()
        for (i, s) in snaps.enumerated() {
            let obj = JSObject.global.Object.function!.new()
            obj.kind = .string(s.kind)
            obj.x = .number(s.x); obj.y = .number(s.y)
            obj.w = .number(s.w); obj.h = .number(s.h)
            obj.vx = .number(s.vx); obj.vy = .number(s.vy)
            obj.alive = .boolean(s.alive)
            obj.owner = .string(s.owner)
            arr[i] = .object(obj)
        }
        return .object(arr)
    }

    // Drop a visual crosshair at world `(x, y)`. Optional 3rd arg is the
    // CSS-style colour ("red"/"green"/"blue"/"yellow"/"white"/"cyan"/"magenta",
    // defaults to magenta). Optional 4th arg is the TTL in milliseconds
    // (default 2000; 0 = persistent until clearMarkers()).
    let marker = JSClosure { args -> JSValue in
        MainActor.assumeIsolated {
            guard let scene = battleScene,
                  let x = args.first?.number,
                  args.count > 1, let y = args[1].number
            else { return }
            let colorName: String = args.count > 2 ? (args[2].string ?? "magenta") : "magenta"
            let ttlMs: Double = args.count > 3 ? (args[3].number ?? 2000) : 2000
            let color: SKColor = {
                switch colorName {
                case "red":     return SKColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
                case "green":   return SKColor(red: 0.2, green: 1, blue: 0.2, alpha: 1)
                case "blue":    return SKColor(red: 0.3, green: 0.6, blue: 1, alpha: 1)
                case "yellow":  return SKColor(red: 1, green: 1, blue: 0.2, alpha: 1)
                case "cyan":    return SKColor(red: 0.2, green: 1, blue: 1, alpha: 1)
                case "white":   return SKColor.white
                default:        return SKColor(red: 1, green: 0.2, blue: 1, alpha: 1)
                }
            }()
            scene.spawnDebugMarker(at: CGPoint(x: x, y: y), color: color, ttl: ttlMs / 1000.0)
        }
        return .undefined
    }

    let clearMarkers = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated { battleScene?.clearDebugMarkers() }
        return .undefined
    }

    // Restart the current battle from the intro. Wraps the private resetBattle
    // path so harness clients don't have to reload the page to retry an attack
    // sequence from a clean slate.
    let resetBattle = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated { battleScene?.debugResetBattle() }
        return .undefined
    }

    // Inspect the boss's currently-active attack. Returns class name + (for
    // OverdriveAttack) the FSM stage and elapsed timer, so the harness can tell
    // whether the desperation laser is stuck before its 1.9s firing window.
    let getActiveAttackInfo = JSClosure { _ -> JSValue in
        let snapshot: (kind: String, isFinished: Bool, stage: String?, timer: Double?, contextAlive: Bool?, laserAlive: Bool?, laserX: Double?, laserY: Double?)? =
            MainActor.assumeIsolated {
                guard let scene = battleScene, let attack = scene.boss.activeAttack else { return nil }
                let kind = String(describing: type(of: attack))
                if let od = attack as? OverdriveAttack {
                    let lp = od.debugLaserPosition
                    return (
                        kind,
                        attack.isFinished,
                        od.debugStageName,
                        Double(od.debugTimer),
                        od.debugContextAlive,
                        od.debugLaserAlive,
                        lp.map { Double($0.x) },
                        lp.map { Double($0.y) }
                    )
                }
                return (kind, attack.isFinished, nil, nil, nil, nil, nil, nil)
            }
        guard let s = snapshot else { return .null }
        let obj = JSObject.global.Object.function!.new()
        obj.kind = .string(s.kind)
        obj.isFinished = .boolean(s.isFinished)
        if let stage = s.stage { obj.stage = .string(stage) }
        if let timer = s.timer { obj.timer = .number(timer) }
        if let alive = s.contextAlive { obj.contextAlive = .boolean(alive) }
        if let alive = s.laserAlive { obj.laserAlive = .boolean(alive) }
        if let lx = s.laserX { obj.laserX = .number(lx) }
        if let ly = s.laserY { obj.laserY = .number(ly) }
        return .object(obj)
    }

    harness.setState = .object(setState)
    harness.release = .object(release)
    harness.pause = .object(pause)
    harness.resume = .object(resume)
    harness.listStates = .object(listStates)
    harness.getInfo = .object(getInfo)
    harness.getBossInfo = .object(getBossInfo)
    harness.setPlayerPosition = .object(setPlayerPosition)
    harness.damageBoss = .object(damageBoss)
    harness.getFrameCount = .object(getFrameCount)
    harness.getAIState = .object(getAIState)
    harness.getPerfStats = .object(getPerfStats)
    harness.disableBoss = .object(disableBoss)
    harness.forceAttack = .object(forceAttack)
    harness.killPlayer = .object(killPlayer)
    harness.getSceneChildren = .object(getSceneChildren)
    harness.step = .object(step)
    harness.resumeRAF = .object(resumeRAF)
    harness.setBossPosition = .object(setBossPosition)
    harness.setBossFacing = .object(setBossFacing)
    harness.setBossHealth = .object(setBossHealth)
    harness.setPlayerHealth = .object(setPlayerHealth)
    harness.getBossMuzzle = .object(getBossMuzzle)
    harness.getProjectiles = .object(getProjectiles)
    harness.marker = .object(marker)
    harness.clearMarkers = .object(clearMarkers)
    harness.resetBattle = .object(resetBattle)
    harness.getActiveAttackInfo = .object(getActiveAttackInfo)
    harness.pressKey = .object(pressKey)
    harness.releaseKeys = .object(releaseKeys)
    harness.forcePlayerAction = .object(forcePlayerAction)
    // JSObject.global IS window in browsers; assign directly.
    JSObject.global.__megaman_test = .object(harness)

    // Keep closures alive — JSObject.global retention isn't enough on its own.
    testHarnessClosures = [
        setState, release, pause, resume, listStates, getInfo, getBossInfo,
        setPlayerPosition, damageBoss, getFrameCount, getAIState, getPerfStats,
        disableBoss, forceAttack, killPlayer, getSceneChildren, step, resumeRAF,
        setBossPosition, setBossFacing, setBossHealth, setPlayerHealth,
        getBossMuzzle, getProjectiles, marker, clearMarkers, resetBattle,
        getActiveAttackInfo, pressKey, releaseKeys, forcePlayerAction
    ]

    print("Test harness installed at window.__megaman_test")
}

private func facingFrom(_ s: String?) -> Facing? {
    switch s {
    case "left": return .left
    case "right": return .right
    default: return nil
    }
}

nonisolated(unsafe) var testHarnessClosures: [JSClosure] = []

// MARK: - Animation loop

@MainActor
func startAnimationLoop() {
    animationCallback = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated {
            guard let skRenderer = renderer else { return }
            // `stepMode` gives the test harness exclusive control of update() —
            // we stop re-scheduling rAF so there's no risk of it interleaving
            // with `step()` calls (which use a separate virtual clock).
            if stepMode { return }
            let now = JSObject.global.performance.now().number ?? 0
            let currentTime = (now - startTime) / 1000.0
            skRenderer.update(atTime: currentTime)
            skRenderer.render()
            frameCount &+= 1
            if let callback = animationCallback {
                _ = JSObject.global.requestAnimationFrame!(callback)
            }
        }
        return .undefined
    }

    if let callback = animationCallback {
        _ = JSObject.global.requestAnimationFrame!(callback)
    }
}

// MARK: - Canvas CSS

nonisolated(unsafe) var resizeHandlerClosure: JSClosure?

@MainActor
func applyPixelArtCanvasCSS(canvas: JSObject) {
    // Aspect-fit the native-resolution canvas into the viewport with pixelated upscaling.
    guard var style = canvas.style.object else { return }
    _ = style.setProperty?("display", "block")
    _ = style.setProperty?("position", "absolute")
    _ = style.setProperty?("top", "50%")
    _ = style.setProperty?("left", "50%")
    _ = style.setProperty?("transform", "translate(-50%, -50%)")
    _ = style.setProperty?("image-rendering", "pixelated")
    _ = style.setProperty?("background-color", "#000")

    sizeCanvasToViewport(canvas: canvas)

    // Keep the aspect-fit size in sync with window resizes.
    let handler = JSClosure { _ -> JSValue in
        MainActor.assumeIsolated {
            sizeCanvasToViewport(canvas: canvas)
        }
        return .undefined
    }
    resizeHandlerClosure = handler
    _ = JSObject.global.addEventListener!("resize", handler)
}

@MainActor
func sizeCanvasToViewport(canvas: JSObject) {
    // Aspect-fit the native canvas to the viewport. Fractional scaling is fine —
    // `image-rendering: pixelated` keeps pixel edges crisp at non-integer multiples.
    let window = JSObject.global
    let innerW = window.innerWidth.number ?? 0
    let innerH = window.innerHeight.number ?? 0
    let scaleX = innerW / Double(GameConfig.gameWidth)
    let scaleY = innerH / Double(GameConfig.gameHeight)
    let scale = max(1, min(scaleX, scaleY))
    let cssW = Double(GameConfig.gameWidth) * scale
    let cssH = Double(GameConfig.gameHeight) * scale
    guard var style = canvas.style.object else { return }
    _ = style.setProperty?("width", "\(Int(cssW))px")
    _ = style.setProperty?("height", "\(Int(cssH))px")
}

print("megaman WASM module loaded — boss battle entry point")
