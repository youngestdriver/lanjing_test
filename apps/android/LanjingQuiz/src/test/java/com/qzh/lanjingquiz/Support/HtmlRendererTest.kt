package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS RichHTMLContentTests.swift 图片解析用例 + 模板契约(§3.5)移植。 */
class HtmlRendererTest {

    // ---- 图片 src 解析(优先 src 后 data-src;实体解码;拒绝 data:;相对路径按上游 base)----

    @Test fun `relative image resolves against upstream base`() {
        assertEquals("https://test.lanjingweike.com/upload/shape.png",
            HtmlRenderer.imageSrc("""<img src="/upload/shape.png" width="200">"""))
    }

    @Test fun `absolute image stays absolute`() {
        assertEquals("https://files.lanjingweike.com/x.png",
            HtmlRenderer.imageSrc("""<img src="https://files.lanjingweike.com/x.png">"""))
    }

    @Test fun `protocol relative image gains https`() {
        assertEquals("https://cdn.lanjingweike.com/a.png",
            HtmlRenderer.imageSrc("""<img src="//cdn.lanjingweike.com/a.png">"""))
    }

    @Test fun `single quoted src and entity decoding`() {
        assertEquals("https://test.lanjingweike.com/upload/a&b.png",
            HtmlRenderer.imageSrc("""<img src='/upload/a&amp;b.png'>"""))
    }

    @Test fun `data-src fallback when src absent`() {
        assertEquals("https://test.lanjingweike.com/upload/lazy.png",
            HtmlRenderer.imageSrc("""<img data-src="/upload/lazy.png">"""))
    }

    @Test fun `image without src is dropped`() {
        assertNull(HtmlRenderer.imageSrc("<img>"))
    }

    @Test fun `data URI is rejected`() {
        assertNull(HtmlRenderer.imageSrc("""<img src="data:image/png;base64,AAAA">"""))
    }

    @Test fun `uppercase img tag`() {
        assertEquals("https://test.lanjingweike.com/up.png",
            HtmlRenderer.imageSrc("""<IMG SRC="/up.png">"""))
    }

    // ---- normalizeImageSrcs 重写 ----

    @Test fun `normalize rewrites data-src into src`() {
        val out = HtmlRenderer.normalizeImageSrcs("<p>图</p><img data-src='/upload/lazy.png'>")
        assertTrue(out.contains("""<img src="https://test.lanjingweike.com/upload/lazy.png">"""))
    }

    @Test fun `normalize keeps existing absolute src`() {
        val out = HtmlRenderer.normalizeImageSrcs("""<img src="https://files.lanjingweike.com/x.png">""")
        assertEquals("""<img src="https://files.lanjingweike.com/x.png">""", out)
    }

    @Test fun `normalize leaves unreadable img untouched`() {
        val out = HtmlRenderer.normalizeImageSrcs("<p>文字</p><img>")
        assertEquals("<p>文字</p><img>", out)
    }

    // ---- document 模板(§3.5)----

    @Test fun `document template light`() {
        val doc = HtmlRenderer.document("<p>hi</p>", fontSizePx = 17, dark = false)
        assertTrue(doc.contains("""<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">"""))
        assertTrue(doc.contains("color: #3c3c3c !important"))
        assertTrue(doc.contains("""font: 17px/1.55 sans-serif"""))
        assertTrue(doc.contains("* { background-color: transparent !important; }"))
        assertFalse(doc.contains("color: inherit"))
        assertTrue(doc.contains("<body><p>hi</p></body>"))
    }

    @Test fun `document template dark forces color inherit`() {
        val doc = HtmlRenderer.document("<p>hi</p>", fontSizePx = 14, dark = true)
        assertTrue(doc.contains("color: #ffffff !important"))
        assertTrue(doc.contains("* { background-color: transparent !important; color: inherit !important; }"))
        assertTrue(doc.contains("""font: 14px/1.55 sans-serif"""))
    }

    // ---- stripTrailingFiller:上游富文本在可见内容末尾追加的空填充块 ----

    /** 真实样本:题干以 <p><br/></p> 结尾(题面与选项间的大空白根因,iOS 用户报告)。 */
    @Test fun `strips real sample trailing empty paragraph`() {
        val style = "box-sizing: border-box; font-family: -apple-system; padding: 0px; line-height: 2rem; color: rgb(60, 70, 79); font-size: 16px"
        assertEquals(
            "<p style=\"$style\">这段文字意在强调（ ）。</p>",
            HtmlRenderer.stripTrailingFiller("<p style=\"$style\">这段文字意在强调（ ）。</p><p><br/></p>"),
        )
    }

    @Test fun `strips consecutive empty paragraphs`() {
        assertEquals("<p>甲</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p><p><br/></p><p>&nbsp;</p>"))
    }

    @Test fun `strips trailing break tags`() {
        assertEquals("<p>甲</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p><br><br/>"))
    }

    @Test fun `strips trailing nbsp runs`() {
        assertEquals("<p>甲</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p>&nbsp;&nbsp;"))
    }

    @Test fun `strips trailing whitespace`() {
        assertEquals("<p>甲</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p>\n \t"))
    }

    @Test fun `strips empty paragraph with nested empty span`() {
        assertEquals("<p>甲</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p><p><span>&nbsp;</span></p>"))
    }

    @Test fun `strips empty div block`() {
        assertEquals("<p>甲</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p><div><br/></div>"))
    }

    @Test fun `strips uppercase filler tags`() {
        assertEquals("<P>甲</P>", HtmlRenderer.stripTrailingFiller("<P>甲</P><P><BR/></P>"))
    }

    @Test fun `document template injects stripped html`() {
        val doc = HtmlRenderer.document("<p>hi</p><p><br/></p>", fontSizePx = 17, dark = false)
        assertTrue(doc.contains("<body><p>hi</p></body>"))
    }

    @Test fun `keeps trailing br inside non-empty paragraph`() {
        assertEquals("<p>甲<br>乙</p>", HtmlRenderer.stripTrailingFiller("<p>甲<br>乙</p>"))
    }

    @Test fun `keeps trailing image`() {
        assertEquals("<p>甲</p><img src=\"/x.png\">", HtmlRenderer.stripTrailingFiller("<p>甲</p><img src=\"/x.png\">"))
    }

    @Test fun `keeps interior blank paragraphs`() {
        assertEquals("<p>甲</p><p><br/></p><p>乙</p>", HtmlRenderer.stripTrailingFiller("<p>甲</p><p><br/></p><p>乙</p>"))
    }

    @Test fun `keeps image inside trailing paragraph`() {
        val html = """<p>看图</p><p><img src="/x.png"></p>"""
        assertEquals(html, HtmlRenderer.stripTrailingFiller(html))
    }

    @Test fun `keeps table inside trailing block`() {
        val html = "<p>甲</p><table><tr><td>乙</td></tr></table>"
        assertEquals(html, HtmlRenderer.stripTrailingFiller(html))
    }

    @Test fun `keeps answer blank inside paragraph`() {
        assertEquals("<p>甲（&nbsp;&nbsp;）。</p>", HtmlRenderer.stripTrailingFiller("<p>甲（&nbsp;&nbsp;）。</p>"))
    }

    @Test fun `filler-only document empties`() {
        assertEquals("", HtmlRenderer.stripTrailingFiller("<p><br/></p><p>&nbsp;</p>"))
    }
}
