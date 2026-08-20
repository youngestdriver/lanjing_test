package com.qzh.lanjingquiz.Data

import com.qzh.lanjingquiz.Domain.BankLogic
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** iOS BankStorageTests.swift 逐字移植:JSONL 容错/原子写/meta 提交点/爬取日志。 */
class BankStorageTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("BankStorageTest-").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun storage() = FileBankStorage(dir)

    private fun meta(round: Int = 26) = BankMeta(
        version = 1, round = round, lastRun = null, targets = emptyList(),
        counts = mapOf("言语理解" to 2),
    )

    private fun files(): Map<String, List<BankQuestion>> =
        BankLogic.categories.associateWith { listOf(makeQuestion("q1")) }

    private fun makeQuestion(id: String, category: String = "言语理解"): BankQuestion = BankQuestion(
        id = id, category = category, section = "逻辑填空", subCategory = "成语辨析",
        question = "<p>题干</p>", stem = null,
        options = listOf("<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"),
        answer = AnswerShape.Single("A"), analysis = null,
        sourceExamName = "【言语理解（二）】机考题库", round = null, collectedAt = null,
    )

    @Test
    fun `writeAll then meta round trips all five categories`() {
        val store = storage()
        assertFalse(store.isPopulated())
        assertNull(store.readMeta())

        store.writeAll(files())
        store.writeMeta(meta())
        assertTrue(store.isPopulated())
        assertEquals(26, store.readMeta()?.round)
        for (category in BankLogic.categories) {
            assertEquals(category, listOf("q1"), store.readCategory(category).map { it.id })
        }
        assertEquals(emptyList<BankQuestion>(), store.readCategory("未知分类"))
    }

    @Test
    fun `isPopulated false when meta missing`() {
        val store = storage()
        // 只写分类文件、无 meta —— 中断的爬取状态
        File(dir, "言语理解.jsonl").writeText("x")
        assertFalse(store.isPopulated())
    }

    @Test
    fun `isPopulated false when counts empty`() {
        val store = storage()
        store.writeAll(files())
        store.writeMeta(meta().copy(counts = emptyMap()))
        assertFalse(store.isPopulated())
    }

    @Test
    fun `appendRecords accumulates without clobbering`() {
        val store = storage()
        store.appendRecords("言语理解", listOf(makeQuestion("q1")))
        store.appendRecords("言语理解", listOf(makeQuestion("q2")))
        assertEquals(listOf("q1", "q2"), store.readCategory("言语理解").map { it.id })
        // 其他分类不受影响
        assertEquals(emptyList<BankQuestion>(), store.readCategory("数字运算"))
        // 空批次 no-op
        store.appendRecords("数字运算", emptyList())
        assertEquals(emptyList<BankQuestion>(), store.readCategory("数字运算"))
    }

    @Test
    fun `saveMeta updates meta without touching files`() {
        val store = storage()
        store.writeMeta(meta(round = 1))
        store.appendRecords("言语理解", listOf(makeQuestion("q1")))
        store.writeMeta(meta(round = 2))
        assertEquals(2, store.readMeta()?.round)
        assertEquals(listOf("q1"), store.readCategory("言语理解").map { it.id })
    }

    @Test
    fun `meta round trips papers field`() {
        val store = storage()
        val m = BankMeta(
            version = 1, round = 3, lastRun = "2026-08-08T00:00:00Z",
            targets = BankLogic.categories, counts = mapOf("言语理解" to 2),
            papers = mapOf("111" to true),
        )
        store.writeMeta(m)
        assertEquals(m, store.readMeta())
    }

    @Test
    fun `clearAll deletes everything`() {
        val store = storage()
        store.writeAll(files())
        store.writeMeta(meta())
        assertTrue(store.isPopulated())
        store.clearAll()
        assertFalse(store.isPopulated())
        assertNull(store.readMeta())
        assertEquals(emptyList<BankQuestion>(), store.readCategory("言语理解"))
    }

    @Test
    fun `jsonl lenient parse ignores unknown keys missing fields corrupt lines and dedupes`() {
        val store = storage()
        File(dir, "言语理解.jsonl").writeText(
            """
            {"_id":"q1","category":"言语理解","question":"<p>Q</p>","sourceExamId":"x1"}
            this is not json
            {"_id":"q1","category":"言语理解"}
            {"_id":"q2","category":"言语理解","answer":["A","C"],"options":["1","2","3","4"]}
            """.trimIndent() + "\n"
        )
        val questions = store.readCategory("言语理解")
        // 未知键 sourceExamId 忽略;缺字段用默认;按 _id 去重(first wins);损坏行丢弃
        assertEquals(listOf("q1", "q2"), questions.map { it.id })
        assertEquals("<p>Q</p>", questions[0].question)
        assertEquals("", questions[0].section)
        assertNull(questions[0].answer)
        assertEquals(AnswerShape.Multi(listOf("A", "C")), questions[1].answer)
        assertEquals(listOf("1", "2", "3", "4"), questions[1].options)
    }

    @Test
    fun `answer three states encode exactly and round trip`() {
        val store = storage()
        store.appendRecords("言语理解", listOf(
            makeQuestion("s1").copy(answer = AnswerShape.Single("A")),
            makeQuestion("m1").copy(answer = AnswerShape.Multi(listOf("A", "C"))),
            makeQuestion("n1").copy(answer = null),
        ))
        val text = File(dir, "言语理解.jsonl").readText()
        // 单选写字符串(绝不一元素数组);多选写数组;无答案写 null
        assertTrue(text.contains("\"answer\":\"A\""))
        assertFalse(text.contains("\"answer\":[\"A\"]"))
        assertTrue(text.contains("\"answer\":[\"A\",\"C\"]"))
        assertTrue(text.contains("\"answer\":null"))

        val questions = store.readCategory("言语理解")
        assertEquals(listOf("s1", "m1", "n1"), questions.map { it.id })
        assertEquals(AnswerShape.Single("A"), questions[0].answer)
        assertEquals(AnswerShape.Multi(listOf("A", "C")), questions[1].answer)
        assertNull(questions[2].answer)
    }

    @Test
    fun `normalizeImgSrcs applied on read for question stem analysis`() {
        val store = storage()
        File(dir, "言语理解.jsonl").writeText(
            """{"_id":"q1","question":"<img src=\"//img.test/a.png\">","stem":"<img src='//img.test/s.png'>","analysis":"<img src=\"https://x/y.png\">","answer":"A"}"""
        )
        val q = store.readCategory("言语理解").single()
        assertEquals("""<img src="https://img.test/a.png">""", q.question)
        assertEquals("""<img src='https://img.test/s.png'>""", q.stem)
        assertEquals("""<img src="https://x/y.png">""", q.analysis)
    }

    @Test
    fun `crawl log starts empty accumulates and survives clear`() {
        val store = storage()
        assertEquals(emptyList<CrawlLogEntry>(), store.readCrawlLog())
        store.appendCrawlLog(entry(step = "enter", outcome = "success"))
        store.appendCrawlLog(entry(step = "save", outcome = "failure"))
        assertEquals(listOf("enter", "save"), store.readCrawlLog().map { it.step })
        assertEquals(listOf("success", "failure"), store.readCrawlLog().map { it.outcome })
        assertEquals(2, store.readCrawlLog().size)
        store.clearAll()
        assertEquals(emptyList<CrawlLogEntry>(), store.readCrawlLog())
    }

    private fun entry(step: String, outcome: String) = CrawlLogEntry(
        timestamp = "2026-08-10T00:10:00Z", paperId = "E1", paperName = "E1",
        step = step, outcome = outcome, message = null,
    )

    @Test
    fun `writeAll failure keeps old content and leaves commit point intact`() {
        val store = storage()
        store.writeAll(files())
        store.writeMeta(meta())
        assertTrue(store.isPopulated())

        // 模拟第二次写失败:"数字运算.jsonl" 被目录占位 → 原子 rename 失败
        val blocker = File(dir, "数字运算.jsonl")
        blocker.delete()
        assertTrue(blocker.mkdirs())

        assertThrows(Exception::class.java) {
            store.writeAll(files().mapValues { (_, v) -> v + makeQuestion("q2") })
        }

        // 提交点(meta)未被触碰;已写文件保持完整(旧或新,不损坏)
        assertEquals(26, store.readMeta()?.round)
        assertEquals(listOf("q1", "q2"), store.readCategory("言语理解").map { it.id })
        for (category in BankLogic.categories.filter { it != "数字运算" && it != "言语理解" }) {
            assertEquals(category, listOf("q1"), store.readCategory(category).map { it.id })
        }
    }
}
