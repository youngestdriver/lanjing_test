import XCTest
@testable import LanjingQuiz

final class ResultPageParserTests: XCTestCase {

    func testScoreParsing() {
        let html = """
        <html><body>
        <div class="score">95</div>
        <span class="exam-result-percentage">88</span>
        <span class="exam-result-percentage">12</span>
        </body></html>
        """
        let result = ResultPageParser.parse(html)
        XCTAssertEqual(result.score, "95")
        XCTAssertEqual(result.beatRate, "88")
        XCTAssertEqual(result.rank, "12")
    }

    func testMissingScoreFallsBackToZero() {
        let result = ResultPageParser.parse("<html><body>no score here</body></html>")
        XCTAssertEqual(result.score, "0")
    }

    func testSinglePercentageReusesForRank() {
        let html = """
        <div class="score">80</div>
        <span class="exam-result-percentage">77</span>
        """
        let result = ResultPageParser.parse(html)
        XCTAssertEqual(result.score, "80")
        XCTAssertEqual(result.beatRate, "77")
        XCTAssertEqual(result.rank, "77")
    }

    func testNoPercentagesFallBackToQuestionMarks() {
        let result = ResultPageParser.parse("<div class=\"score\">60</div>")
        XCTAssertEqual(result.score, "60")
        XCTAssertEqual(result.beatRate, "?")
        XCTAssertEqual(result.rank, "?")
    }

    func testEmptyHTML() {
        let result = ResultPageParser.parse("")
        XCTAssertEqual(result.score, "0")
        XCTAssertEqual(result.beatRate, "?")
        XCTAssertEqual(result.rank, "?")
    }
}
