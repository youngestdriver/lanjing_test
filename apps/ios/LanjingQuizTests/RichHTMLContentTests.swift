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

    // MARK: - Paragraph segmentation

    func testParagraphPartsTextOnly() {
        let parts = RichHTMLContent.paragraphParts(of: "<p>甲</p><p>乙</p>")
        XCTAssertEqual(parts.count, 2)
        guard case .text(let first) = parts[0], case .text(let second) = parts[1] else {
            return XCTFail("expected two text parts")
        }
        XCTAssertTrue(first.contains("甲"))
        XCTAssertTrue(second.contains("乙"))
    }

    func testParagraphPartsStandaloneImageBlock() {
        let img = "https://x.com/chart.png"
        let parts = RichHTMLContent.paragraphParts(
            of: "<p>题干文字</p><p><img src=\"\(img)\" class=\"ksx-ue-question-image\"/></p><p>选项文字</p>"
        )
        XCTAssertEqual(parts.count, 3)
        guard case .image(let url) = parts[1] else {
            return XCTFail("standalone image block must be an image part, got \(parts[1])")
        }
        XCTAssertEqual(url, img)
    }

    func testParagraphPartsInlineFormulaStaysMixed() {
        // 行内公式:图与文字同一段 → 整段走 WebView 保真。
        let block = "<p>若 a=<img flag=\"tex\" src=\"https://x.com/f.png\">,则 ( )</p>"
        let parts = RichHTMLContent.paragraphParts(of: block)
        XCTAssertEqual(parts.count, 1)
        guard case .mixed(let inner) = parts[0] else {
            return XCTFail("inline formula block must stay mixed, got \(parts[0])")
        }
        XCTAssertEqual(inner, block)
    }

    func testParagraphPartsImageOnlyOption() {
        let img = "https://x.com/formula.png"
        let parts = RichHTMLContent.paragraphParts(of: "<p><img flag=\"tex\" src=\"\(img)\"> </p>")
        XCTAssertEqual(parts.count, 1)
        guard case .image(let url) = parts[0] else {
            return XCTFail("image-only option must be an image part, got \(parts[0])")
        }
        XCTAssertEqual(url, img)
    }

    func testParagraphPartsResidualText() {
        let parts = RichHTMLContent.paragraphParts(of: "<p>甲</p>残留")
        XCTAssertEqual(parts.count, 2)
        guard case .text(let residual) = parts[1] else {
            return XCTFail("residual text should be a text part")
        }
        XCTAssertTrue(residual.contains("残留"))
    }

    // MARK: - contentParts(本地化接缝)

    /// 回归锁:localize 把 src 换成 data: URI,一旦在**分段之前**做,
    /// 独立图段就会拿到 data: URI —— 而 LocalBankImage 是按 remote URL
    /// 查 SwiftData 的,永远查不中 → 整块图永久灰条。分段必须先于本地化:
    /// 图段保留原始 remote URL,只有混排段(WebView)才拿本地化后的 HTML。
    @MainActor
    func testImagePartsKeepRawRemoteURLWhileMixedPartsGetLocalized() {
        let remote = "https://x.com/chart.png"
        let html = "<p>材料</p><p><img src=\"\(remote)\"></p><p>若 a=<img src=\"\(remote)\">,则（ ）</p>"
        let parts = RichHTMLContent.contentParts(of: html) { localized in
            localized.replacingOccurrences(of: remote, with: "data:image/png;base64,AAAA")
        }
        XCTAssertEqual(parts.count, 3)

        guard case .text(let textHTML) = parts[0] else {
            return XCTFail("expected text part, got \(parts[0])")
        }
        XCTAssertEqual(textHTML, "<p>材料</p>")

        guard case .image(let imageURL) = parts[1] else {
            return XCTFail("standalone image block must be an image part, got \(parts[1])")
        }
        XCTAssertEqual(imageURL, remote, "独立图段必须携带原始 remote URL,否则 resolver 查不到 → 永久灰条")

        guard case .mixed(let mixedHTML) = parts[2] else {
            return XCTFail("inline formula block must stay mixed, got \(parts[2])")
        }
        XCTAssertTrue(mixedHTML.contains("data:image/png"), "混排段交给 WebView,必须已本地化")
    }
}
