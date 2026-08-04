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
}
