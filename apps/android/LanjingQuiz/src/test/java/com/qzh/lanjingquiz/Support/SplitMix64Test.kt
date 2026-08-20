package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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

    @Test fun `nextBits 32 takes the high bits of the long`() {
        // 旧实现 (1 shl 32) - 1 == 0 → nextBits(32) 恒 0;修复后为 nextLong 的高 32 位
        assertEquals(-1861603860, SplitMix64(1UL).nextBits(32))
        assertEquals(-1109970394, SplitMix64(42UL).nextBits(32))
    }

    @Test fun `same seed reproduces sequence`() {
        val a = SplitMix64(42UL)
        val b = SplitMix64(42UL)
        repeat(10) { assertEquals(a.nextLong(), b.nextLong()) }
    }

    @Test fun `shuffle order is seed-dependent and deterministic`() {
        // 黄金值(修复后实现实测,Python 交叉核验);非 2 的幂有界 nextInt 走 nextBits(32),
        // 旧实现 nextBits(32) 恒 0,洗牌结果与种子无关 → 该断言在旧实现上失败
        assertEquals(listOf(5, 0, 1, 4, 3, 2), (0..5).toList().shuffled(SplitMix64(1UL)))
        assertEquals(listOf(5, 0, 1, 4, 3, 2), (0..5).toList().shuffled(SplitMix64(1UL)))
        assertNotEquals(listOf(5, 0, 1, 4, 3, 2), (0..5).toList().shuffled(SplitMix64(2UL)))
    }

    @Test fun `bounded nextInt stays in range and is deterministic`() {
        val rng = SplitMix64(42UL)
        val seq = (0 until 100).map { rng.nextInt(1000) }
        assertTrue(seq.all { it in 0 until 1000 })
        val again = SplitMix64(42UL)
        assertEquals(seq, (0 until 100).map { again.nextInt(1000) })
    }
}
