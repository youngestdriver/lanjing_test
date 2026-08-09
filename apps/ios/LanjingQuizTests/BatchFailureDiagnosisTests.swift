import XCTest
@testable import LanjingQuiz

/// Diagnosis text for undecodable question batches (APIClient.describeBatchFailure)
/// — the crawl log's "which question, why" detail.
final class BatchFailureDiagnosisTests: XCTestCase {

    private func diagnose(status: Int, text: String, testIds: [String], batchIndex: Int = 0, batchCount: Int = 1) -> String {
        APIClient.describeBatchFailure(
            status: status,
            batchIndex: batchIndex,
            batchCount: batchCount,
            testIds: testIds,
            responseText: text
        )
    }

    func testIdentifiesBatchAndQuestionIds() {
        let text = diagnose(status: 200, text: "not json at all", testIds: ["q1", "q2", "q3"])
        XCTAssertTrue(text.contains("第 1/1 批（3 题）响应无法解析，HTTP 200"))
        XCTAssertTrue(text.contains("涉及题目：q1、q2、q3"))
        XCTAssertTrue(text.contains("上游响应：not json at all"))
    }

    func testNamesMalformedArrayElementsByTheirId() {
        let body = """
        [
          {"_id": "q1", "question": "<p>正常</p>", "answer1": "A"},
          {"_id": "q2", "question": 12345},
          {"broken": true}
        ]
        """
        let text = diagnose(status: 200, text: body, testIds: ["q1", "q2", "q3"])
        XCTAssertTrue(text.contains("坏元素：q2（question 非字符串）、第3个（缺 _id）"), text)
        // healthy elements are not flagged
        XCTAssertFalse(text.contains("坏元素：q1"))
    }

    func testNamesElementsMissingQuestion() {
        let body = """
        [
          {"_id": "c1", "question": "<p>有题干</p>", "key1": "1"},
          {"_id": "c2", "key1": "0"}
        ]
        """
        let text = diagnose(status: 200, text: body, testIds: ["c1", "c2"])
        XCTAssertTrue(text.contains("坏元素：c2（缺 question）"), text)
        XCTAssertFalse(text.contains("坏元素：c1"))
    }

    func testReportsBatchPositionAndResponseHead() {
        let text = diagnose(status: 500, text: "服务开小差了，请稍后再试", testIds: ["q9"], batchIndex: 2, batchCount: 4)
        XCTAssertTrue(text.contains("第 3/4 批（1 题）响应无法解析，HTTP 500"))
        XCTAssertTrue(text.contains("涉及题目：q9"))
    }
}
