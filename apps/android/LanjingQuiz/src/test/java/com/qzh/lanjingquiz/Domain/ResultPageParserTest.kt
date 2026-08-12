package com.qzh.lanjingquiz.Domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** iOS ResultPageParserTests.swift 逐字移植。 */
class ResultPageParserTest {

    @Test fun `score parsing`() {
        val html = """
        <html><body>
        <div class="score">95</div>
        <span class="exam-result-percentage">88</span>
        <span class="exam-result-percentage">12</span>
        </body></html>
        """
        val result = ResultPageParser.parse(html)
        assertEquals("95", result.score)
        assertEquals("88", result.beatRate)
        assertEquals("12", result.rank)
    }

    @Test fun `missing score falls back to zero`() {
        val result = ResultPageParser.parse("<html><body>no score here</body></html>")
        assertEquals("0", result.score)
    }

    @Test fun `single percentage reuses for rank`() {
        val html = """
        <div class="score">80</div>
        <span class="exam-result-percentage">77</span>
        """
        val result = ResultPageParser.parse(html)
        assertEquals("80", result.score)
        assertEquals("77", result.beatRate)
        assertEquals("77", result.rank)
    }

    @Test fun `no percentages fall back to question marks`() {
        val result = ResultPageParser.parse("""<div class="score">60</div>""")
        assertEquals("60", result.score)
        assertEquals("?", result.beatRate)
        assertEquals("?", result.rank)
    }

    @Test fun `empty html`() {
        val result = ResultPageParser.parse("")
        assertEquals("0", result.score)
        assertEquals("?", result.beatRate)
        assertEquals("?", result.rank)
    }
}
