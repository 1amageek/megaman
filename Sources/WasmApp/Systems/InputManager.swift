import Foundation
import JavaScriptKit

// MARK: - Input Manager
// Bridges browser keyboard events to game-readable state.
// OpenSpriteKit does not expose input, so we wire DOM listeners directly.

@MainActor
final class InputManager {
    static let shared = InputManager()

    // Held state — true for the entire duration a key is held down.
    private(set) var left: Bool = false
    private(set) var right: Bool = false
    private(set) var up: Bool = false
    private(set) var down: Bool = false
    private(set) var jump: Bool = false
    private(set) var shoot: Bool = false
    private(set) var dash: Bool = false

    // Edge-triggered state — true for exactly one frame after press.
    private(set) var jumpPressed: Bool = false
    private(set) var shootPressed: Bool = false
    private(set) var dashPressed: Bool = false
    // Direction edges — Godot `Input.is_action_just_pressed("left"/"right")` /
    // `get_just_pressed_axis()`. Damage._EndCondition reads this for the
    // "wall + matching just-pressed input" early-recover branch.
    private(set) var leftPressed: Bool = false
    private(set) var rightPressed: Bool = false

    // Previous frame's held state, used to compute pressed edges.
    private var prevJump: Bool = false
    private var prevShoot: Bool = false
    private var prevDash: Bool = false
    private var prevLeft: Bool = false
    private var prevRight: Bool = false

    private var keyDownCallback: JSClosure?
    private var keyUpCallback: JSClosure?

    // Gamepad state — mirrors the previous-frame Web Gamepad API readout so
    // pollGamepad() emits press/release transitions instead of every-frame
    // re-presses (which would re-arm edge triggers each tick).
    private var prevButtonPressed: [Int: Bool] = [:]
    private var prevAxisLeft = false
    private var prevAxisRight = false
    private var prevAxisUp = false
    private var prevAxisDown = false
    // Gamepad polling is off by default — `getGamepads()` allocates a fresh
    // JSObject per pad/button each frame and bloats the WASM heap to OOM
    // over a long session. Flipped on by `gamepadconnected`, off by
    // `gamepaddisconnected`.
    private var hasConnectedGamepad: Bool = false
    private var gamepadConnectedCallback: JSClosure?
    private var gamepadDisconnectedCallback: JSClosure?

    private init() {}

    func setup() {
        let keyDown = JSClosure { args -> JSValue in
            MainActor.assumeIsolated {
                guard let event = args.first?.object,
                      let key = event.key.string else { return }
                self.handle(key: key, down: true)
            }
            return JSValue.undefined
        }
        let keyUp = JSClosure { args -> JSValue in
            MainActor.assumeIsolated {
                guard let event = args.first?.object,
                      let key = event.key.string else { return }
                self.handle(key: key, down: false)
            }
            return JSValue.undefined
        }

        keyDownCallback = keyDown
        keyUpCallback = keyUp

        let document = JSObject.global.document
        _ = document.addEventListener("keydown", keyDown)
        _ = document.addEventListener("keyup", keyUp)

        // Listen on `window` for gamepad connect events. We never poll
        // `getGamepads()` until at least one pad has connected — the API
        // returns a 4-slot array that allocates per call and OOMs the WASM
        // heap if hit every frame.
        let connected = JSClosure { _ -> JSValue in
            MainActor.assumeIsolated { self.hasConnectedGamepad = true }
            return .undefined
        }
        let disconnected = JSClosure { _ -> JSValue in
            MainActor.assumeIsolated {
                guard let getGamepads = JSObject.global.navigator.object?.getGamepads.function else {
                    self.hasConnectedGamepad = false
                    return
                }
                let pads = getGamepads()
                guard let length = pads.length.number else {
                    self.hasConnectedGamepad = false
                    return
                }
                var anyStillConnected = false
                for i in 0..<Int(length) {
                    if pads[i].connected.boolean == true { anyStillConnected = true }
                }
                self.hasConnectedGamepad = anyStillConnected
            }
            return .undefined
        }
        gamepadConnectedCallback = connected
        gamepadDisconnectedCallback = disconnected
        let window = JSObject.global.window
        _ = window.addEventListener("gamepadconnected", connected)
        _ = window.addEventListener("gamepaddisconnected", disconnected)
    }

    // Advance frame — must be called once per tick AFTER game logic samples edges.
    func endFrame() {
        prevJump = jump
        prevShoot = shoot
        prevDash = dash
        prevLeft = left
        prevRight = right
        jumpPressed = false
        shootPressed = false
        dashPressed = false
        leftPressed = false
        rightPressed = false
    }

    /// Test-only: drive input from the harness without dispatching DOM events.
    /// Mirrors the keydown/keyup pipeline so edge triggers (jumpPressed etc.)
    /// fire on the next frame just like real keyboard input.
    func setKey(_ key: String, down: Bool) {
        handle(key: key, down: down)
    }

    /// Test-only: clear every held key in one call. Used by the harness's
    /// `releaseKeys` helper between scenarios so a leftover ArrowRight from a
    /// prior capture doesn't leak into the next.
    func clearAllKeys() {
        left = false; right = false; up = false; down = false
        jump = false; shoot = false; dash = false
        prevJump = false; prevShoot = false; prevDash = false
        prevLeft = false; prevRight = false
        jumpPressed = false; shootPressed = false; dashPressed = false
        leftPressed = false; rightPressed = false
    }

    /// Poll the Web Gamepad API once per frame and forward press/release
    /// transitions through the same `setKey` path as the keyboard. Standard
    /// gamepad mapping: button 0 = jump, 1 = dash, 2 = shoot, d-pad 12-15 =
    /// directions, axes 0/1 = left analog with 0.3 dead-zone.
    func pollGamepad() {
        // No pad has fired a connect event yet — skip the entire JS bridge
        // dance, which is the per-frame allocator that previously OOM'd
        // long-running E2E sessions.
        guard hasConnectedGamepad else { return }
        guard let getGamepads = JSObject.global.navigator.object?.getGamepads.function else { return }
        let pads = getGamepads()
        guard let length = pads.length.number, length > 0 else { return }

        var pressed: [Int: Bool] = [:]
        var leftAxis = false, rightAxis = false, upAxis = false, downAxis = false

        for i in 0..<Int(length) {
            let pad = pads[i]
            guard pad.connected.boolean == true else { continue }
            if let buttons = pad.buttons.object,
               let bLen = buttons.length.number {
                for b in 0..<Int(bLen) {
                    let btn = buttons[b]
                    let isPressed: Bool
                    if let bool = btn.pressed.boolean {
                        isPressed = bool
                    } else if let v = btn.value.number {
                        isPressed = v >= 0.5
                    } else {
                        isPressed = false
                    }
                    if isPressed { pressed[b] = true }
                }
            }
            if let axes = pad.axes.object,
               let aLen = axes.length.number,
               aLen >= 2 {
                let x = axes[0].number ?? 0
                let y = axes[1].number ?? 0
                let dz = 0.3
                if x < -dz { leftAxis = true }
                if x > dz { rightAxis = true }
                if y < -dz { upAxis = true }
                if y > dz { downAxis = true }
            }
        }

        // Buttons 0/1/2 → jump/dash/shoot. Forward only on transitions so
        // edge triggers (jumpPressed etc.) fire exactly once per press.
        emitButton(index: 0, pressedNow: pressed[0] == true, key: " ")
        emitButton(index: 1, pressedNow: pressed[1] == true, key: "c")
        emitButton(index: 2, pressedNow: pressed[2] == true, key: "x")
        // D-pad
        emitButton(index: 12, pressedNow: pressed[12] == true, key: "arrowup")
        emitButton(index: 13, pressedNow: pressed[13] == true, key: "arrowdown")
        emitButton(index: 14, pressedNow: pressed[14] == true, key: "arrowleft")
        emitButton(index: 15, pressedNow: pressed[15] == true, key: "arrowright")

        // Analog stick (treated like d-pad once dead-zoned).
        emitAxis(prev: &prevAxisLeft, now: leftAxis, key: "arrowleft")
        emitAxis(prev: &prevAxisRight, now: rightAxis, key: "arrowright")
        emitAxis(prev: &prevAxisUp, now: upAxis, key: "arrowup")
        emitAxis(prev: &prevAxisDown, now: downAxis, key: "arrowdown")
    }

    private func emitButton(index: Int, pressedNow: Bool, key: String) {
        let prev = prevButtonPressed[index] == true
        if pressedNow != prev {
            handle(key: key, down: pressedNow)
            prevButtonPressed[index] = pressedNow
        }
    }

    private func emitAxis(prev: inout Bool, now: Bool, key: String) {
        if now != prev {
            handle(key: key, down: now)
            prev = now
        }
    }

    private func handle(key: String, down pressed: Bool) {
        switch key.lowercased() {
        case "arrowleft", "a":
            if pressed && !prevLeft { leftPressed = true }
            left = pressed
        case "arrowright", "d":
            if pressed && !prevRight { rightPressed = true }
            right = pressed
        case "arrowup", "w":
            up = pressed
        case "arrowdown", "s":
            down = pressed
        case " ", "z":
            if pressed && !prevJump { jumpPressed = true }
            jump = pressed
        case "x", "j":
            if pressed && !prevShoot { shootPressed = true }
            shoot = pressed
        case "c", "shift", "k":
            if pressed && !prevDash { dashPressed = true }
            dash = pressed
        default:
            break
        }
    }
}
