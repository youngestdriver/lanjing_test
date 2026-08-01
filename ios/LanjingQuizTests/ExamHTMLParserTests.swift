import XCTest
@testable import LanjingQuiz

final class ExamHTMLParserTests: XCTestCase {

    func testParsesStatesAndSections() {
        let result = ExamHTMLParser.parse(Fixtures.examStartHTML, fallbackExamInfoId: "fallback")

        XCTAssertEqual(result.examResultsId, "87380582")
        XCTAssertEqual(result.examInfoId, "1439658")
        XCTAssertEqual(result.uuid, "u1")

        // q5 is a duplicate of q1 → deduped
        XCTAssertEqual(result.testIds, ["q1", "q2", "q3", "q4"])
        XCTAssertEqual(result.questionStates.count, 4)

        let q1 = result.questionStates[0]
        XCTAssertEqual(q1.questionsId, "q1")
        XCTAssertEqual(q1.uuId, "u1")
        XCTAssertEqual(q1.num, 1)
        XCTAssertEqual(q1.section, "科技常识")
        XCTAssertEqual(q1.state, .right)
        XCTAssertTrue(q1.marked)

        let q2 = result.questionStates[1]
        XCTAssertEqual(q2.state, .error)
        XCTAssertFalse(q2.marked)
        XCTAssertEqual(q2.section, "科技常识")

        let q3 = result.questionStates[2]
        XCTAssertEqual(q3.state, .unanswered)
        XCTAssertEqual(q3.section, "逻辑推理")

        let q4 = result.questionStates[3]
        XCTAssertEqual(q4.state, .right)
        XCTAssertEqual(q4.section, "逻辑推理")
    }

    func testSectionMapCounts() {
        let result = ExamHTMLParser.parse(Fixtures.examStartHTML, fallbackExamInfoId: "fallback")

        XCTAssertEqual(result.sectionOrder, ["科技常识", "逻辑推理"])
        let first = result.sectionMap["科技常识"]
        XCTAssertEqual(first?.total, 2)
        XCTAssertEqual(first?.right, 1)
        XCTAssertEqual(first?.error, 1)
        XCTAssertEqual(first?.unanswered, 0)

        let second = result.sectionMap["逻辑推理"]
        XCTAssertEqual(second?.total, 2)
        XCTAssertEqual(second?.right, 1)
        XCTAssertEqual(second?.unanswered, 1)
    }

    func testNoSectionsUsesDefaultKey() {
        let result = ExamHTMLParser.parse(Fixtures.examStartNoSectionsHTML, fallbackExamInfoId: "888")

        XCTAssertEqual(result.examResultsId, "999")
        XCTAssertEqual(result.sectionMap["(无分类)"]?.total, 1)
        XCTAssertEqual(result.sectionOrder, ["(无分类)"])
        XCTAssertEqual(result.questionStates[0].section, "")
    }

    func testKnownResultsIdOverrides() {
        let result = ExamHTMLParser.parse(Fixtures.examStartHTML, fallbackExamInfoId: "fallback", knownResultsId: "12345")
        XCTAssertEqual(result.examResultsId, "12345")
    }

    func testFallbackExamInfoId() {
        let html = Fixtures.examStartHTML.replacingOccurrences(of: "var exam_info_id = '1439658';", with: "")
        let result = ExamHTMLParser.parse(html, fallbackExamInfoId: "fallback-id")
        XCTAssertEqual(result.examInfoId, "fallback-id")
    }

    func testMissingResultsIdIsNil() {
        let html = Fixtures.examStartHTML.replacingOccurrences(of: "var exam_results_id = '87380582';", with: "")
        let result = ExamHTMLParser.parse(html, fallbackExamInfoId: "fallback")
        XCTAssertNil(result.examResultsId)
    }

    func testEmptyHTML() {
        let result = ExamHTMLParser.parse(Fixtures.examStartMinimalHTML, fallbackExamInfoId: "fallback")
        XCTAssertNil(result.examResultsId)
        XCTAssertEqual(result.examInfoId, "fallback")
        XCTAssertTrue(result.questionStates.isEmpty)
        XCTAssertTrue(result.testIds.isEmpty)
        XCTAssertTrue(result.sectionMap.isEmpty)
    }

    func testEmptyString() {
        let result = ExamHTMLParser.parse("", fallbackExamInfoId: "fallback")
        XCTAssertNil(result.examResultsId)
        XCTAssertTrue(result.questionStates.isEmpty)
    }
}
