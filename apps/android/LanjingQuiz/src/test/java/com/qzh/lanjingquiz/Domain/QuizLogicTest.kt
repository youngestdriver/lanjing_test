package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Fixtures
import com.qzh.lanjingquiz.Support.Formatters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS QuizLogicTests.swift / PracticeUpstreamMappingTests 相关用例移植。 */
class QuizLogicTest {

    // ---- correctLetters ----

    @Test fun `correctLetters single key`() {
        assertEquals(listOf("A"), QuizLogic.correctLetters(Fixtures.questionDTO("q1", keys = listOf("1", "0", "0", "0"))))
        assertEquals(listOf("C"), QuizLogic.correctLetters(Fixtures.questionDTO("q1", keys = listOf("0", "0", "1", "0"))))
    }

    @Test fun `correctLetters multi keys`() {
        assertEquals(listOf("A", "C"), QuizLogic.correctLetters(Fixtures.questionDTO("q1", keys = listOf("1", "0", "1", "0"))))
    }

    @Test fun `correctLetters falls back to testAnsRight when all zero`() {
        val dto = Fixtures.questionDTO("q1", keys = listOf("0", "0", "0", "0"), testAnsRight = "D")
        assertEquals(listOf("D"), QuizLogic.correctLetters(dto))
        assertTrue(QuizLogic.isGradable(dto))
    }

    @Test fun `correctLetters empty when all zero and no fallback`() {
        val dto = Fixtures.questionDTO("q1", keys = listOf("0", "0", "0", "0"), testAnsRight = "")
        assertEquals(emptyList<String>(), QuizLogic.correctLetters(dto))
        assertFalse(QuizLogic.isGradable(dto))
    }

    // ---- letterFor / isMulti ----

    @Test fun `letterFor single answer`() {
        assertEquals("A", QuizLogic.letterFor(Fixtures.questionDTO("q1", keys = listOf("1", "0", "0", "0"))))
        assertEquals("C", QuizLogic.letterFor(Fixtures.questionDTO("q1", keys = listOf("0", "0", "1", "0"))))
        // 全 0 + test_ans_right 回退 → 单选
        assertEquals("D", QuizLogic.letterFor(Fixtures.questionDTO("q1", keys = listOf("0", "0", "0", "0"), testAnsRight = "D")))
    }

    @Test fun `letterFor multi or none is null`() {
        assertNull(QuizLogic.letterFor(Fixtures.questionDTO("q1", keys = listOf("1", "0", "1", "0"))))
        assertNull(QuizLogic.letterFor(Fixtures.questionDTO("q1", keys = listOf("0", "0", "0", "0"), testAnsRight = "")))
    }

    @Test fun `isMulti from key flags`() {
        assertFalse(QuizLogic.isMulti(Fixtures.questionDTO("q1", keys = listOf("1", "0", "0", "0"))))
        assertTrue(QuizLogic.isMulti(Fixtures.questionDTO("q1", keys = listOf("1", "0", "1", "0"))))
        assertFalse(QuizLogic.isMulti(Fixtures.questionDTO("q1", keys = listOf("0", "0", "0", "0"))))
    }

    // ---- lettersToKeys / keysToLetters ----

    @Test fun `lettersToKeys sorts dedupes and appends trailing comma`() {
        assertEquals("key1,key3,", QuizLogic.lettersToKeys(listOf("C", "A")))
        assertEquals("key1,", QuizLogic.lettersToKeys(listOf("A")))
        assertEquals("key1,key3,", QuizLogic.lettersToKeys(listOf("A", "C", "A")))
        assertEquals("", QuizLogic.lettersToKeys(emptyList()))
    }

    @Test fun `keysToLetters tolerates junk and dedupes`() {
        assertEquals(listOf("A", "C"), QuizLogic.keysToLetters("key3,key1,key3,unknown,"))
        assertEquals(listOf("B", "D"), QuizLogic.keysToLetters("key4,key2,key4,"))
        assertEquals(emptyList<String>(), QuizLogic.keysToLetters(""))
    }

    // ---- optionResult(规则逐字 spec §五)----

    @Test fun `optionResult marks only reference and selected wrong options`() {
        // 单选答对:只有参考答案 ✅
        assertEquals(OptionMarker.Correct, QuizLogic.optionResult(
            isAnswered = true, isSelected = true, isCorrect = true, isMulti = false, questionState = "right"))
        assertNull(QuizLogic.optionResult(
            isAnswered = true, isSelected = false, isCorrect = false, isMulti = false, questionState = "right"))

        // 单选答错:选中 ❌、参考答案 ✅、未触碰保持原色
        assertEquals(OptionMarker.Wrong, QuizLogic.optionResult(
            isAnswered = true, isSelected = true, isCorrect = false, isMulti = false, questionState = "error"))
        assertEquals(OptionMarker.Correct, QuizLogic.optionResult(
            isAnswered = true, isSelected = false, isCorrect = true, isMulti = false, questionState = "error"))
        assertNull(QuizLogic.optionResult(
            isAnswered = true, isSelected = false, isCorrect = false, isMulti = false, questionState = "error"))

        // 多选:选中参考答案与选中错误项可同时存在
        assertEquals(OptionMarker.Correct, QuizLogic.optionResult(
            isAnswered = true, isSelected = true, isCorrect = true, isMulti = true, questionState = "error"))
        assertEquals(OptionMarker.Wrong, QuizLogic.optionResult(
            isAnswered = true, isSelected = true, isCorrect = false, isMulti = true, questionState = "error"))

        // 未答 → null;无答案题(isCorrect = null):选中 → Wrong(无正确答案,选中即错),其余 → 无标记
        assertNull(QuizLogic.optionResult(
            isAnswered = false, isSelected = true, isCorrect = true, isMulti = false, questionState = "unanswered"))
        assertEquals(OptionMarker.Wrong, QuizLogic.optionResult(
            isAnswered = true, isSelected = true, isCorrect = null, isMulti = false, questionState = "error"))
        assertNull(QuizLogic.optionResult(
            isAnswered = true, isSelected = false, isCorrect = null, isMulti = false, questionState = "error"))
    }

    // ---- nextIndex ----

    @Test fun `nextIndex skips to unanswered`() {
        val s = listOf("right", "unanswered", "unanswered")
        assertEquals(1, QuizLogic.nextIndex(after = 0, states = s))
        assertEquals(2, QuizLogic.nextIndex(after = 1, states = s))
    }

    @Test fun `nextIndex wraps around`() {
        val s = listOf("unanswered", "right")
        assertEquals(0, QuizLogic.nextIndex(after = 1, states = s))
    }

    @Test fun `nextIndex falls back to next index when all answered`() {
        val s = listOf("right", "right")
        assertEquals(1, QuizLogic.nextIndex(after = 0, states = s))
        assertEquals(1, QuizLogic.nextIndex(after = 1, states = s))
    }

    @Test fun `nextIndex empty states`() {
        assertEquals(0, QuizLogic.nextIndex(after = 0, states = emptyList()))
    }

    // ---- mmss / section tab label(iOS QuizLogicTests 其余用例)----

    @Test fun `mmss formatting`() {
        assertEquals("00:00", Formatters.mmss(0))
        assertEquals("00:01", Formatters.mmss(1))
        assertEquals("00:59", Formatters.mmss(59))
        assertEquals("01:00", Formatters.mmss(60))
        assertEquals("01:01", Formatters.mmss(61))
        assertEquals("10:00", Formatters.mmss(600))
    }

    @Test fun `section tab short label`() {
        assertEquals("科技常识", QuizLogic.sectionTabLabel("科技常识(单选)"))
        assertEquals("无括号标题", QuizLogic.sectionTabLabel("无括号标题"))
        assertEquals("", QuizLogic.sectionTabLabel("(以括号开头)"))
    }
}
