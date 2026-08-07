import XCTest
@testable import LanjingQuiz

final class BankModelTests: XCTestCase {

    private func makeQuestion(
        answer: BankQuestion.Answer? = BankQuestion.Answer(letters: ["A"]),
        question: String = "<p>题干</p>",
        options: [String] = ["<p>A选项</p>", "<p>B选项</p>", "<p>C选项</p>", "<p>D选项</p>"],
        analysis: String? = "<p>解析</p>"
    ) -> BankQuestion {
        BankQuestion(
            id: "b1",
            category: "言语理解",
            section: "逻辑填空",
            subCategory: "成语辨析",
            question: question,
            options: options,
            answer: answer,
            analysis: analysis,
            sourceExamName: "【言语理解（二）】机考题库",
            round: nil,
            collectedAt: nil
        )
    }

    func testAnswerMapping() {
        // single letter
        let single = makeQuestion(answer: .init(letters: ["A"]))
        XCTAssertEqual(single.answer?.letters, ["A"])
        XCTAssertEqual(single.keys, [true, false, false, false])
        XCTAssertEqual(single.correctAnswers, ["A"])
        XCTAssertFalse(single.isMulti)
        XCTAssertTrue(single.isGradable)

        // multi letters
        let multi = makeQuestion(answer: .init(letters: ["B", "D"]))
        XCTAssertEqual(multi.keys, [false, true, false, true])
        XCTAssertTrue(multi.isMulti)
        XCTAssertEqual(multi.correctAnswers, ["B", "D"])

        // nil answer → ungradable, all keys false
        let none = makeQuestion(answer: nil)
        XCTAssertNil(none.answer)
        XCTAssertEqual(none.keys, [false, false, false, false])
        XCTAssertFalse(none.isGradable)
    }

    func testPreservesEmptyOptionSlots() {
        let question = makeQuestion(options: ["<p>A</p>", "", "", "<p>D</p>"])
        XCTAssertEqual(question.options, ["<p>A</p>", "", "", "<p>D</p>"])
        XCTAssertEqual(question.letters, ["A", "B", "C", "D"]) // slots preserved for answer alignment
    }

    func testNormalizesProtocolRelativeImgSrcs() {
        let question = makeQuestion(
            question: "<p>公式<img src=\"//fb.fbstatic.cn/1.png\">和<img src='//x.cn/2.png'></p>"
        )
        XCTAssertEqual(question.question, "<p>公式<img src=\"https://fb.fbstatic.cn/1.png\">和<img src='https://x.cn/2.png'></p>")
    }

    func testLeavesAbsoluteImgSrcsUntouched() {
        let html = "<p><img src=\"https://fb.fbstatic.cn/1.png\">已<url>正常</p>"
        let question = makeQuestion(question: html)
        XCTAssertEqual(question.question, html)
    }

    func testNormalizesAnalysisImagesToo() {
        let question = makeQuestion(analysis: "<p><img src='//x.cn/a.png'></p>")
        XCTAssertEqual(question.analysis, "<p><img src='https://x.cn/a.png'></p>")
    }
}
