package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SplitMix64Test {
    @Test fun `deterministic sequence for fixed seed`() {
        val rng = SplitMix64(1UL)
        // 与 iOS SeededGenerator 同算法(spec §3.6);序列经 Python 独立实现校验
        assertEquals(-7995527694508729151L, rng.nextLong())
        assertEquals(-4689498862643123097L, rng.nextLong())
        assertEquals(-534904783426661026L, rng.nextLong())
        assertEquals(8196980753821780235L, rng.nextLong())
        assertEquals(8195237237126968761L, rng.nextLong())
    }

    @Test fun `same seed reproduces sequence`() {
        val a = SplitMix64(42UL)
        val b = SplitMix64(42UL)
        repeat(10) { assertEquals(a.nextLong(), b.nextLong()) }
    }

    @Test fun `bounded nextInt stays in range and is deterministic`() {
        val rng = SplitMix64(42UL)
        val seq = (0 until 100).map { rng.nextInt(1000) }
        assertTrue(seq.all { it in 0 until 1000 })
        val again = SplitMix64(42UL)
        assertEquals(seq, (0 until 100).map { again.nextInt(1000) })
    }
}
