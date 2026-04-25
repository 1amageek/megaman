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

    // Previous frame's held state, used to compute pressed edges.
    private var prevJump: Bool = false
    private var prevShoot: Bool = false
    private var prevDash: Bool = false

    private var keyDownCallback: JSClosure?
    private var keyUpCallback: JSClosure?

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
    }

    // Advance frame — must be called once per tick AFTER game logic samples edges.
    func endFrame() {
        prevJump = jump
        prevShoot = shoot
        prevDash = dash
        jumpPressed = false
        shootPressed = false
        dashPressed = false
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
        jumpPressed = false; shootPressed = false; dashPressed = false
    }

    private func handle(key: String, down pressed: Bool) {
        switch key.lowercased() {
        case "arrowleft", "a":
            left = pressed
        case "arrowright", "d":
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
