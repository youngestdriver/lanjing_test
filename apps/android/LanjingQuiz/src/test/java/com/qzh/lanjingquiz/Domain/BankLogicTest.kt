package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.PracticeAnswer
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Support.SplitMix64
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** iOS BankLogicTests.swift + PracticeSessionTests.swift 恢复规则用例移植。 */
class BankLogicTest {

    private val json = Json { encodeDefaults = true }

    private fun makeQuestion(
        id: String,
        subCategory: String = "类",
        answer: AnswerShape? = AnswerShape.Single("A"),
        stem: String? = null,
    ): BankQuestion = BankQuestion(
        id = id, category = "言语理解", section = "逻辑填空", subCategory = subCategory,
        question = "<p>题干</p>", stem = stem,
        options = listOf("<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"),
        answer = answer, analysis = null, sourceExamName = null, round = null, collectedAt = null,
    )

    private fun questions(ids: List<String>, subCategory: String? = null): List<BankQuestion> =
        ids.mapIndexed { index, id -> makeQuestion(id, subCategory = subCategory ?: "类${index % 2}") }

    // MARK: - parseJsonl

    @Test
    fun `parseJsonl drops malformed lines and blank lines`() {
        val text = listOf(
            json.encodeToString(BankQuestion.serializer(), makeQuestion("q1")),
            "this is not json",
            json.encodeToString(BankQuestion.serializer(), makeQuestion("q2", subCategory = "实词辨析")),
            "", // blank line skipped
        ).joinToString("\n")
        assertEquals(listOf("q1", "q2"), BankLogic.parseJsonl(text).map { it.id })
    }

    @Test
    fun `parseJsonl dedupes by id keeping first occurrence`() {
        val text = listOf(
            json.encodeToString(BankQuestion.serializer(), makeQuestion("q1", subCategory = "首个")),
            json.encodeToString(BankQuestion.serializer(), makeQuestion("q1", subCategory = "重复")),
        ).joinToString("\n")
        val parsed = BankLogic.parseJsonl(text)
        assertEquals(1, parsed.size)
        assertEquals("首个", parsed[0].subCategory)
    }

    // MARK: - resumeCandidate

    private val ordered: List<BankQuestion>
        get() = listOf(makeQuestion("q1"), makeQuestion("q2"), makeQuestion("q3"))

    /** 3 题中途会话:q1 答对、q2 答错、q3 待答。 */
    private fun makeSession(): PracticeSession = PracticeSession(
        category = "言语理解", subCategory = "成语辨析", questions = ordered,
        index = 1,
        answers = listOf(
            PracticeAnswer(selected = listOf("A"), revealed = true, correct = true),
            PracticeAnswer(selected = listOf("B"), revealed = true, correct = false),
            PracticeAnswer(),
        ),
    )

    @Test
    fun `resumeCandidate matches unfinished same order`() {
        assertEquals(makeSession(), BankLogic.resumeCandidate(makeSession(), "言语理解", "成语辨析", ordered))
    }

    @Test
    fun `resumeCandidate matches different id order`() {
        // 随机顺序(洗牌)只改变顺序、不改变 ID 集合 → 必须恢复存档(需求 3)
        val shuffled = listOf(makeQuestion("q2"), makeQuestion("q1"), makeQuestion("q3"))
        assertEquals(makeSession(), BankLogic.resumeCandidate(makeSession(), "言语理解", "成语辨析", shuffled))
    }

    @Test
    fun `resumeCandidate rejects different id set`() {
        // 题库更新后 ID 集合变化(增/删题)→ 存档失效,全新开始
        val changedBank = listOf(makeQuestion("q1"), makeQuestion("q2"), makeQuestion("q4"))
        assertNull(BankLogic.resumeCandidate(makeSession(), "言语理解", "成语辨析", changedBank))
    }

    @Test
    fun `resumeCandidate rejects different category`() {
        assertNull(BankLogic.resumeCandidate(makeSession(), "数字运算", "成语辨析", ordered))
    }

    @Test
    fun `resumeCandidate rejects different subCategory`() {
        assertNull(BankLogic.resumeCandidate(makeSession(), "言语理解", "其他", ordered))
    }

    @Test
    fun `resumeCandidate rejects finished`() {
        val finished = makeSession().copy(index = ordered.size)
        assertNull(BankLogic.resumeCandidate(finished, "言语理解", "成语辨析", ordered))
    }

    @Test
    fun `resumeCandidate rejects nil saved`() {
        assertNull(BankLogic.resumeCandidate(null, "言语理解", "成语辨析", ordered))
    }

    // MARK: - shuffle

    @Test
    fun `shuffled is deterministic for same seed`() {
        val source = questions((0 until 30).map { "q$it" }, subCategory = "类")
        val a = BankLogic.shuffledKeepingGroups(source, SplitMix64(42UL))
        val b = BankLogic.shuffledKeepingGroups(source, SplitMix64(42UL))
        assertEquals(a.map { it.id }, b.map { it.id })
    }

    @Test
    fun `shuffled permutes for different seed`() {
        val source = questions((0 until 30).map { "q$it" }, subCategory = "类")
        val a = BankLogic.shuffledKeepingGroups(source, SplitMix64(1UL))
        val b = BankLogic.shuffledKeepingGroups(source, SplitMix64(2UL))
        assertNotEquals(a.map { it.id }, b.map { it.id })
        assertEquals(source.map { it.id }.toSet(), a.map { it.id }.toSet()) // same members
    }

    @Test
    fun `shuffledKeepingGroups keeps same stem adjacent`() {
        val source = listOf(
            makeQuestion("n1", stem = null),
            makeQuestion("a1", stem = "<p>材料A</p>"),
            makeQuestion("a2", stem = "<p>材料A</p>"),
            makeQuestion("n2", stem = null),
            makeQuestion("b1", stem = "<p>材料B</p>"),
            makeQuestion("a3", stem = "<p>材料A</p>"),
        )
        val shuffled = BankLogic.shuffledKeepingGroups(source, SplitMix64(7UL))
        assertEquals(source.map { it.id }.toSet(), shuffled.map { it.id }.toSet()) // same members
        // 大序号 group members must stay adjacent (both orders allowed)
        val positions = shuffled.mapIndexed { i, q -> q.id to i }.toMap()
        for (group in listOf(listOf("a1", "a2", "a3"), listOf("b1"))) {
            val indexes = group.map { positions.getValue(it) }.sorted()
            assertEquals("$group split apart", indexes, (indexes.first() until indexes.first() + group.size).toList())
        }
    }

    @Test
    fun `shuffledKeepingGroups preserves intra-group order`() {
        val source = listOf(
            makeQuestion("a1", stem = "<p>材料A</p>"),
            makeQuestion("a2", stem = "<p>材料A</p>"),
            makeQuestion("b1", stem = "<p>材料B</p>"),
            makeQuestion("a3", stem = "<p>材料A</p>"),
            makeQuestion("b2", stem = "<p>材料B</p>"),
        )
        for (seed in listOf(1UL, 2UL, 3UL, 7UL, 42UL)) {
            val shuffled = BankLogic.shuffledKeepingGroups(source, SplitMix64(seed))
            val aIds = shuffled.filter { it.stem == "<p>材料A</p>" }.map { it.id }
            val bIds = shuffled.filter { it.stem == "<p>材料B</p>" }.map { it.id }
            assertEquals(listOf("a1", "a2", "a3"), aIds)
            assertEquals(listOf("b1", "b2"), bIds)
        }
    }

    @Test
    fun `shuffledKeepingGroups is deterministic for same seed`() {
        val source = listOf(
            makeQuestion("n1"),
            makeQuestion("a1", stem = "<p>材料A</p>"),
            makeQuestion("a2", stem = "<p>材料A</p>"),
            makeQuestion("n2"),
            makeQuestion("b1", stem = "<p>材料B</p>"),
            makeQuestion("a3", stem = "<p>材料A</p>"),
        )
        val a = BankLogic.shuffledKeepingGroups(source, SplitMix64(42UL))
        val b = BankLogic.shuffledKeepingGroups(source, SplitMix64(42UL))
        assertEquals(a.map { it.id }, b.map { it.id })
    }

    @Test
    fun `shuffledKeepingGroups without stems is a plain shuffle`() {
        val source = questions((0 until 20).map { "q$it" }, subCategory = "类")
        val shuffled = BankLogic.shuffledKeepingGroups(source, SplitMix64(9UL))
        assertEquals(source.map { it.id }.toSet(), shuffled.map { it.id }.toSet())
        assertNotEquals(source.map { it.id }, shuffled.map { it.id }) // actually permuted
    }

    @Test
    fun `groupShuffleQuestions seed variant matches rng variant`() {
        val source = questions((0 until 20).map { "q$it" }, subCategory = "类")
        assertEquals(
            BankLogic.shuffledKeepingGroups(source, SplitMix64(11UL)).map { it.id },
            BankLogic.groupShuffleQuestions(source, 11UL).map { it.id },
        )
    }
}
