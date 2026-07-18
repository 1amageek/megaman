import Foundation
import JavaScriptKit

// MARK: - AudioManager
// Thin facade over the browser's HTMLAudioElement. BGM is a single looping
// element retained for stop control; SFX are fire-and-forget — a fresh
// Audio is constructed per play so multiple shots can overlap (the browser
// HTTP-caches the .wav body, so re-construction is cheap).
//
// Browsers block playback until a user gesture. We listen for the first
// keydown/pointerdown/touchstart and unlock; any BGM requested before that
// is stashed and replayed on unlock.

@MainActor
final class AudioManager {
    static let shared = AudioManager()

    private var bgm: JSObject?
    private var bgmURL: String?
    private var bgmVolume: Double = 0.4
    private var sfxVolume: Double = 0.7
    private var unlocked: Bool = false
    private var unlockClosures: [JSClosure] = []

    private init() {}

    func setup() {
        let document = JSObject.global.document
        let unlock = JSClosure { _ -> JSValue in
            MainActor.assumeIsolated {
                self.unlock()
            }
            return .undefined
        }
        unlockClosures.append(unlock)
        _ = document.addEventListener("keydown", unlock)
        _ = document.addEventListener("pointerdown", unlock)
        _ = document.addEventListener("touchstart", unlock)
    }

    private func unlock() {
        guard !unlocked else { return }
        unlocked = true
        if let url = bgmURL {
            startBGM(url: url, volume: bgmVolume)
        }
    }

    // MARK: - BGM

    func playBGM(url: String, volume: Double = 0.4) {
        bgmVolume = volume
        bgmURL = url
        guard unlocked else { return }
        startBGM(url: url, volume: volume)
    }

    private func startBGM(url: String, volume: Double) {
        if let bgm = bgm { _ = bgm.pause?() }
        guard let ctor = JSObject.global.Audio.function else { return }
        let audio = ctor.new(url)
        audio["loop"] = .boolean(true)
        audio["volume"] = .number(volume)
        _ = audio.play?()
        bgm = audio
    }

    func stopBGM() {
        if let bgm = bgm { _ = bgm.pause?() }
        bgm = nil
        bgmURL = nil
    }

    // MARK: - SFX

    func playSFX(_ url: String, volume: Double? = nil) {
        guard unlocked else { return }
        guard let ctor = JSObject.global.Audio.function else { return }
        let audio = ctor.new(url)
        audio["volume"] = .number(volume ?? sfxVolume)
        _ = audio.play?()
    }
}

// MARK: - Asset URLs
// String constants centralised so call-sites stay readable and there is
// exactly one place to rename a file.

enum AudioAssets {
    // BGM
    static let sigmaLoop = "assets/audio/bgm/sigma_loop.ogg"

    // Player SFX
    static let jump = "assets/audio/sfx/jump.wav"
    static let dash = "assets/audio/sfx/dash.wav"
    static let shot = "assets/audio/sfx/shot.wav"
    static let chargeMax = "assets/audio/sfx/charge_max.wav"
    static let chargedShot = "assets/audio/sfx/charged_shot.wav"
    static let damage = "assets/audio/sfx/damage.wav"
    static let death = "assets/audio/sfx/death.wav"

    // Common
    static let explosion = "assets/audio/sfx/explosion.wav"

    // Boss SFX
    static let bossAppear = "assets/audio/sfx/boss_appear.wav"
    static let bossDeath = "assets/audio/sfx/boss_death.wav"
    static let sigmaLaser = "assets/audio/sfx/sigma_laser.wav"
    static let hitBoss = "assets/audio/sfx/hit_boss.wav"
}
