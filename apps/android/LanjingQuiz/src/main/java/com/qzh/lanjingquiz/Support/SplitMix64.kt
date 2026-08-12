package com.qzh.lanjingquiz.Support

import kotlin.random.Random

/** SplitMix64 确定性 RNG,与 iOS SeededGenerator 同算法(spec §3.6)。 */
class SplitMix64(seed: ULong) : Random() {
    private var state = seed
    override fun nextBits(bitCount: Int): Int = (nextLong() ushr (64 - bitCount)).toInt()
    override fun nextLong(): Long {
        state += 0x9E3779B97F4A7C15UL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9UL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBUL
        return (z xor (z shr 31)).toLong()
    }
}
