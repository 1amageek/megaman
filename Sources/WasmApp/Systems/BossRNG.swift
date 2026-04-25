import Foundation

// MARK: - Deterministic Boss RNG
// Mirrors Mega-Man-X8-16-bit/src/Actors/Bosses/BossRNG.gd:
// seeded random used by attack scheduler.

struct BossRNG {
    private var state: UInt64

    init(seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64 — standard, deterministic, no dependencies.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }

    mutating func randi(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func randf(in range: ClosedRange<Double>) -> Double {
        // `Int` is 32-bit on wasm32: `1 &<< 53` would mask the shift to (53 & 31)
        // and produce 2^21 instead of 2^53, yielding a unit value far outside
        // [0, 1). Use UInt64 for the 53-bit denominator explicitly.
        let unit = Double(next() &>> 11) / Double(UInt64(1) &<< 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
