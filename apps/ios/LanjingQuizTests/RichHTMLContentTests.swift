import XCTest
@testable import LanjingQuiz

final class RichHTMLContentTests: XCTestCase {

    func testNoImagesSingleTextSegment() {
        let segments = RichHTMLContent.segments(from: "<p>1+1=?</p>")
        XCTAssertEqual(segments.count, 1)
        guard case .text(let html) = segments[0] else {
            return XCTFail("expected text segment")
        }
        XCTAssertEqual(html, "<p>1+1=?</p>")
    }

    func testMixedTextAndImage() {
        let html = """
        <p>观察下图：</p>
        <img src="/upload/shape.png" width="200">
        <p>请问下一个是什么？</p>
        """
        let segments = RichHTMLContent.segments(from: html)
        XCTAssertEqual(segments.count, 3)
        guard case .text = segments[0], case .image(let url) = segments[1], case .text = segments[2] else {
            return XCTFail("expected text/image/text")
        }
        XCTAssertEqual(url.absoluteString, "https://test.lanjingweike.com/upload/shape.png")
    }

    func testAbsoluteImageURL() {
        let html = #"<img src="https://files.lanjingweike.com/x.png">"#
        let segments = RichHTMLContent.segments(from: html)
        guard case .image(let url) = segments[0] else {
            return XCTFail("expected image segment")
        }
        XCTAssertEqual(url.absoluteString, "https://files.lanjingweike.com/x.png")
    }

    func testProtocolRelativeImageURL() {
        let html = #"<img src="//cdn.lanjingweike.com/a.png">"#
        let segments = RichHTMLContent.segments(from: html)
        guard case .image(let url) = segments[0] else {
            return XCTFail("expected image segment")
        }
        XCTAssertEqual(url.absoluteString, "https://cdn.lanjingweike.com/a.png")
    }

    func testSingleQuotedSrcAndEntityDecoding() {
        let html = #"<img src='/upload/a&amp;b.png'>"#
        let segments = RichHTMLContent.segments(from: html)
        guard case .image(let url) = segments[0] else {
            return XCTFail("expected image segment")
        }
        XCTAssertEqual(url.absoluteString, "https://test.lanjingweike.com/upload/a&b.png")
    }

    func testDataSrcFallback() {
        let html = #"<img data-src="/upload/lazy.png" src="placeholder.gif">"#
        let segments = RichHTMLContent.segments(from: html)
        guard case .image(let url) = segments[0] else {
            return XCTFail("expected image segment")
        }
        XCTAssertEqual(url.absoluteString, "https://test.lanjingweike.com/upload/lazy.png")
    }

    func testImageWithoutSrcIsDropped() {
        let html = "<p>文字</p><img>"
        let segments = RichHTMLContent.segments(from: html)
        XCTAssertEqual(segments.count, 1)
        guard case .text(let text) = segments[0] else {
            return XCTFail("expected text segment")
        }
        XCTAssertEqual(text, "<p>文字</p>")
    }

    func testDataURIIsDropped() {
        let html = #"<img src="data:image/png;base64,AAAA">"#
        let segments = RichHTMLContent.segments(from: html)
        XCTAssertTrue(segments.isEmpty || !segments.contains { if case .image = $0 { return true } else { return false } })
    }

    func testUppercaseImgTag() {
        let html = #"<IMG SRC="/up.png">"#
        let segments = RichHTMLContent.segments(from: html)
        guard case .image(let url) = segments[0] else {
            return XCTFail("expected image segment")
        }
        XCTAssertEqual(url.absoluteString, "https://test.lanjingweike.com/up.png")
    }

    // MARK: - stripTrailingFiller (题面与选项间的空白, 根因 = 尾部 <p><br/></p>)

    /// 真实样本:上游题干以 <p><br/></p> 结尾。
    func testStripTrailingFillerRealSample() {
        let style = "box-sizing: border-box; font-family: -apple-system; padding: 0px; line-height: 2rem; color: rgb(60, 70, 79); font-size: 16px"
        let text = "<p style=\"\(style)\">这段文字意在强调（ ）。</p>"
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller(text + "<p><br/></p>"), text)
    }

    func testStripTrailingFillerConsecutiveEmptyParagraphs() {
        XCTAssertEqual(
            RichHTMLContent.stripTrailingFiller("<p>甲</p><p><br/></p><p>&nbsp;</p>"),
            "<p>甲</p>"
        )
    }

    func testStripTrailingFillerBreakTags() {
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller("<p>甲</p><br><br/>"), "<p>甲</p>")
    }

    func testStripTrailingFillerNbspRuns() {
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller("<p>甲</p>&nbsp;&nbsp;"), "<p>甲</p>")
    }

    func testStripTrailingFillerWhitespace() {
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller("<p>甲</p>\n \t"), "<p>甲</p>")
    }

    func testStripTrailingFillerNestedEmptySpan() {
        XCTAssertEqual(
            RichHTMLContent.stripTrailingFiller("<p>甲</p><p><span>&nbsp;</span></p>"),
            "<p>甲</p>"
        )
    }

    func testStripTrailingFillerEmptyDivBlock() {
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller("<p>甲</p><div><br/></div>"), "<p>甲</p>")
    }

    func testStripTrailingFillerUppercaseTags() {
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller("<P>甲</P><P><BR/></P>"), "<P>甲</P>")
    }

    func testStripTrailingFillerKeepsBreakInsideParagraph() {
        XCTAssertEqual(
            RichHTMLContent.stripTrailingFiller("<p>甲<br>乙</p>"),
            "<p>甲<br>乙</p>"
        )
    }

    func testStripTrailingFillerKeepsTrailingImage() {
        XCTAssertEqual(
            RichHTMLContent.stripTrailingFiller(#"<p>甲</p><img src="/x.png">"#),
            #"<p>甲</p><img src="/x.png">"#
        )
    }

    func testStripTrailingFillerKeepsInteriorBlankParagraphs() {
        XCTAssertEqual(
            RichHTMLContent.stripTrailingFiller("<p>甲</p><p><br/></p><p>乙</p>"),
            "<p>甲</p><p><br/></p><p>乙</p>"
        )
    }

    func testStripTrailingFillerKeepsImageInsideTrailingParagraph() {
        let html = #"<p>看图</p><p><img src="/x.png"></p>"#
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller(html), html)
    }

    func testStripTrailingFillerKeepsTableInsideTrailingBlock() {
        let html = "<p>甲</p><table><tr><td>乙</td></tr></table>"
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller(html), html)
    }

    func testStripTrailingFillerKeepsAnswerBlank() {
        XCTAssertEqual(
            RichHTMLContent.stripTrailingFiller("<p>甲（&nbsp;&nbsp;）。</p>"),
            "<p>甲（&nbsp;&nbsp;）。</p>"
        )
    }

    func testStripTrailingFillerEmptiesFillerOnlyDocument() {
        XCTAssertEqual(RichHTMLContent.stripTrailingFiller("<p><br/></p><p>&nbsp;</p>"), "")
    }
}
