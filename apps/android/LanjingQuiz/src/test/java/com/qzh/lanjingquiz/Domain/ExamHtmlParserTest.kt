package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS ExamHTMLParserTests.swift 逐字移植(HTML 夹具见 Fixtures)。 */
class ExamHtmlParserTest {

    @Test fun `parses states and sections`() {
        val page = ExamHtmlParser.parse(Fixtures.examStartHTML, fallbackExamInfoId = "fallback")

        assertEquals("87380582", page.examResultsId)
        assertEquals("1439658", page.examInfoId)
        assertEquals("u1", page.uuid)

        // q5 是 q1 的重复 → 去重
        assertEquals(listOf("q1", "q2", "q3", "q4"), page.cards.map { it.questionsId })
        assertEquals(4, page.cards.size)

        val q1 = page.cards[0]
        assertEquals("q1", q1.questionsId)
        assertEquals("u1", q1.uuId)
        assertEquals("1", q1.number)
        assertNull(q1.combId)
        assertEquals("科技常识", q1.section)
        assertEquals("right", q1.state)
        assertTrue(q1.marked)

        val q2 = page.cards[1]
        assertEquals("error", q2.state)
        assertFalse(q2.marked)
        assertEquals("科技常识", q2.section)

        val q3 = page.cards[2]
        assertEquals("unanswered", q3.state)
        assertEquals("逻辑推理", q3.section)

        val q4 = page.cards[3]
        assertEquals("right", q4.state)
        assertEquals("逻辑推理", q4.section)
    }

    @Test fun `parses comb sections with sub numbers and combId`() {
        val page = ExamHtmlParser.parse(Fixtures.examStartCombHTML, fallbackExamInfoId = "E2")

        assertEquals(3, page.cards.size)
        assertEquals("c1", page.cards[0].questionsId)
        assertEquals("1.1", page.cards[0].number)
        assertEquals("comb_wa", page.cards[0].combId)
        assertEquals("文字资料(共15题,合计75.0分)", page.cards[0].section)

        assertEquals("15.5", page.cards[1].number)
        assertEquals("comb_wa", page.cards[1].combId)

        // comb section 之后的常规卡片不得继承 combId
        assertEquals("reg1", page.cards[2].questionsId)
        assertEquals("16", page.cards[2].number)
        assertNull(page.cards[2].combId)
        assertEquals("言语理解", page.cards[2].section)

        assertEquals(listOf("文字资料(共15题,合计75.0分)", "言语理解"), page.sections)
        assertEquals(2, page.cards.count { it.section == "文字资料(共15题,合计75.0分)" })
        assertEquals(1, page.cards.count { it.section == "言语理解" })
    }

    @Test fun `section counts`() {
        val page = ExamHtmlParser.parse(Fixtures.examStartHTML, fallbackExamInfoId = "fallback")

        assertEquals(listOf("科技常识", "逻辑推理"), page.sections)
        val first = page.cards.filter { it.section == "科技常识" }
        assertEquals(2, first.size)
        assertEquals(1, first.count { it.state == "right" })
        assertEquals(1, first.count { it.state == "error" })
        assertEquals(0, first.count { it.state == "unanswered" })

        val second = page.cards.filter { it.section == "逻辑推理" }
        assertEquals(2, second.size)
        assertEquals(1, second.count { it.state == "right" })
        assertEquals(1, second.count { it.state == "unanswered" })
    }

    @Test fun `no sections uses default key`() {
        val page = ExamHtmlParser.parse(Fixtures.examStartNoSectionsHTML, fallbackExamInfoId = "888")

        assertEquals("999", page.examResultsId)
        assertEquals(listOf("(无分类)"), page.sections)
        assertEquals(1, page.cards.size)
        assertEquals("", page.cards[0].section)
    }

    @Test fun `known results id overrides`() {
        val page = ExamHtmlParser.parse(Fixtures.examStartHTML, fallbackExamInfoId = "fallback", knownResultsId = "12345")
        assertEquals("12345", page.examResultsId)
    }

    @Test fun `fallback exam info id`() {
        val html = Fixtures.examStartHTML.replace("var exam_info_id = '1439658';", "")
        val page = ExamHtmlParser.parse(html, fallbackExamInfoId = "fallback-id")
        assertEquals("fallback-id", page.examInfoId)
    }

    @Test fun `missing results id is empty`() {
        val html = Fixtures.examStartHTML.replace("var exam_results_id = '87380582';", "")
        val page = ExamHtmlParser.parse(html, fallbackExamInfoId = "fallback")
        assertEquals("", page.examResultsId)
    }

    @Test fun `empty html`() {
        val page = ExamHtmlParser.parse(Fixtures.examStartMinimalHTML, fallbackExamInfoId = "fallback")
        assertEquals("", page.examResultsId)
        assertEquals("fallback", page.examInfoId)
        assertTrue(page.cards.isEmpty())
        assertTrue(page.sections.isEmpty())
    }

    @Test fun `empty string`() {
        val page = ExamHtmlParser.parse("", fallbackExamInfoId = "fallback")
        assertEquals("", page.examResultsId)
        assertTrue(page.cards.isEmpty())
    }
}
