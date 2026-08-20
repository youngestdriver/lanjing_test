package com.qzh.lanjingquiz.Data

import com.qzh.lanjingquiz.Domain.BankLogic
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** iOS PracticeProgressStoreTests.swift + PracticeBankViewModelTests 聚合用例移植。 */
class PracticeProgressStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("PracticeProgressStoreTest-").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun store() = FilePracticeProgressStore(dir)

    @Test
    fun `load returns empty map when absent`() = runBlocking {
        assertEquals(emptyMap<String, PracticeProgress>(), store().load())
    }

    @Test
    fun `save load round trip`() = runBlocking {
        val store = store()
        val progress = mapOf("言语理解/成语辨析" to PracticeProgress(listOf("q1", "q2")))
        store.save(progress)
        assertEquals(progress, store.load())
    }

    @Test
    fun `clear removes file`() = runBlocking {
        val store = store()
        store.save(mapOf("言语理解/成语辨析" to PracticeProgress(listOf("q1"))))
        store.clear()
        assertEquals(emptyMap<String, PracticeProgress>(), store.load())
    }

    @Test
    fun `category aggregation sums answered ids by key prefix`() {
        // 大类聚合 = 键前缀求和(iOS: 1 本会话成语辨析 + 2 预置虚词辨析)
        val progress = mapOf(
            "言语理解/成语辨析" to PracticeProgress(listOf("q1")),
            "言语理解/虚词辨析" to PracticeProgress(listOf("x1", "x2")),
            "数字运算/速算" to PracticeProgress(listOf("y1")),
        )
        assertEquals(1, BankLogic.answeredCount(progress, "言语理解", "成语辨析"))
        assertEquals(3, BankLogic.answeredCount(progress, "言语理解"))
        assertEquals(1, BankLogic.answeredCount(progress, "数字运算"))
        assertEquals(0, BankLogic.answeredCount(progress, "逻辑推理"))
    }
}
