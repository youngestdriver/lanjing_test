package com.qzh.lanjingquiz.Data

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** iOS PracticeSessionTests.swift 移植:往返/缺失/clear/乱序 selected 集合语义。 */
class PracticeSessionStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("PracticeSessionStoreTest-").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun store() = FilePracticeSessionStore(dir)

    private fun makeQuestion(id: String): BankQuestion = BankQuestion(
        id = id, category = "言语理解", section = "逻辑填空", subCategory = "成语辨析",
        question = "<p>题干 $id</p>", stem = null,
        options = listOf("<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"),
        answer = AnswerShape.Single("A"), analysis = null,
        sourceExamName = "【言语理解（二）】机考题库", round = null, collectedAt = null,
    )

    /** 3 题中途会话:q1 答对、q2 答错、q3 待答。 */
    private fun makeSession(): PracticeSession = PracticeSession(
        category = "言语理解", subCategory = "成语辨析",
        questions = listOf(makeQuestion("q1"), makeQuestion("q2"), makeQuestion("q3")),
        index = 1,
        answers = listOf(
            PracticeAnswer(selected = listOf("A"), revealed = true, correct = true),
            PracticeAnswer(selected = listOf("B"), revealed = true, correct = false),
            PracticeAnswer(),
        ),
    )

    @Test
    fun `load returns null when absent`() = runBlocking {
        assertNull(store().load())
    }

    @Test
    fun `save load round trip`() = runBlocking {
        val store = store()
        store.save(makeSession())
        val loaded = store.load()
        assertEquals(makeSession(), loaded)
        assertEquals(1, loaded!!.index)
        assertEquals(listOf("A"), loaded.answers[0].selected)
        assertEquals(true, loaded.answers[0].correct)
        assertEquals(false, loaded.answers[1].correct)
        assertEquals(emptyList<String>(), loaded.answers[2].selected)
        assertFalse(loaded.answers[2].revealed)
        assertNull(loaded.answers[2].correct)
        // 题干 HTML 往返无损
        assertEquals(listOf("q1", "q2", "q3"), loaded.questions.map { it.id })
        assertEquals("<p>题干 q1</p>", loaded.questions[0].question)
    }

    @Test
    fun `clear removes file`() = runBlocking {
        val store = store()
        store.save(makeSession())
        assertEquals(makeSession(), store.load())
        store.clear()
        assertNull(store.load())
    }

    @Test
    fun `ungradable answer round trips as nil verdict`() = runBlocking {
        val store = store()
        val session = makeSession().copy(
            answers = listOf(
                PracticeAnswer(selected = listOf("A"), revealed = true, correct = true),
                PracticeAnswer(selected = listOf("B"), revealed = true, correct = false),
                PracticeAnswer(selected = listOf("C"), revealed = true, correct = null),
            ),
        )
        store.save(session)
        val loaded = store.load()
        assertEquals(session, loaded)
        assertTrue(loaded!!.answers[2].revealed)
        assertNull(loaded.answers[2].correct)
        assertEquals(listOf("C"), loaded.answers[2].selected)
    }

    @Test
    fun `unordered selected input reads normalized sorted`() = runBlocking {
        // iOS Set 编码顺序不定 → selected 乱序 JSON 仍按集合语义读入并排序归一
        val file = File(dir, "practice-session.json")
        file.writeText(
            """{"category":"言语理解","subCategory":"成语辨析","questions":[],"index":0,"answers":[{"selected":["B","A"],"revealed":true,"correct":true},{"selected":["C","D"],"revealed":false}]}"""
        )
        val session = store().load()
        assertEquals(listOf("A", "B"), session!!.answers[0].selected)
        assertEquals(listOf("C", "D"), session.answers[1].selected)
        assertNull(session.answers[1].correct)
        assertFalse(session.answers[1].revealed)
    }
}
