import XCTest
@testable import LanjingQuiz

final class BankModelTests: XCTestCase {

    private func decode(_ line: String) -> BankQuestion? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BankQuestion.self, from: data)
    }

    func testDecodesRealFormatLine() throws {
        let question = try XCTUnwrap(decode(Fixtures.bankRecord()))
        XCTAssertEqual(question.id, "b1")
        XCTAssertEqual(question.category, "言语理解")
        XCTAssertEqual(question.section, "逻辑填空")
        XCTAssertEqual(question.subCategory, "成语辨析")
        XCTAssertEqual(question.question, "<p>题干</p>")
        XCTAssertEqual(question.options, ["<p>A选项</p>", "<p>B选项</p>", "<p>C选项</p>", "<p>D选项</p>"])
        XCTAssertEqual(question.answer?.letters, ["A"])
        XCTAssertEqual(question.analysis, "<p>解析</p>")
        XCTAssertEqual(question.sourceExamName, "【言语理解（二）】机考题库")
        XCTAssertEqual(question.round, 4)
        XCTAssertEqual(question.collectedAt, "2026-08-07T00:00:00.000Z")
        XCTAssertTrue(question.isGradable)
        XCTAssertFalse(question.isMulti)
    }

    func testAnswerMapping() throws {
        // single letter
        let single = try XCTUnwrap(decode(Fixtures.bankRecord(answer: .single("A"))))
        XCTAssertEqual(single.keys, [true, false, false, false])
        XCTAssertEqual(single.correctAnswers, ["A"])

        // multi letters
        let multi = try XCTUnwrap(decode(Fixtures.bankRecord(answer: .multi(["B", "D"]))))
        XCTAssertEqual(multi.keys, [false, true, false, true])
        XCTAssertTrue(multi.isMulti)
        XCTAssertEqual(multi.correctAnswers, ["B", "D"])

        // null answer → ungradable, all keys false
        let none = try XCTUnwrap(decode(Fixtures.bankRecord(answer: .none)))
        XCTAssertNil(none.answer)
        XCTAssertEqual(none.keys, [false, false, false, false])
        XCTAssertFalse(none.isGradable)
    }

    func testPreservesEmptyOptionSlots() throws {
        let question = try XCTUnwrap(decode(Fixtures.bankRecord(options: ["<p>A</p>", "", "", "<p>D</p>"])))
        XCTAssertEqual(question.options, ["<p>A</p>", "", "", "<p>D</p>"])
        XCTAssertEqual(question.letters, ["A", "B", "C", "D"]) // slots preserved for answer alignment
    }

    func testNormalizesProtocolRelativeImgSrcs() throws {
        let question = try XCTUnwrap(decode(Fixtures.bankRecord(
            question: "<p>公式<img src=\"//fb.fbstatic.cn/1.png\">和<img src='//x.cn/2.png'></p>"
        )))
        XCTAssertEqual(question.question, "<p>公式<img src=\"https://fb.fbstatic.cn/1.png\">和<img src='https://x.cn/2.png'></p>")
    }

    func testLeavesAbsoluteImgSrcsUntouched() throws {
        let html = "<p><img src=\"https://fb.fbstatic.cn/1.png\">已<url>正常</p>"
        let question = try XCTUnwrap(decode(Fixtures.bankRecord(question: html)))
        XCTAssertEqual(question.question, html)
    }

    func testNormalizesAnalysisImagesToo() throws {
        let question = try XCTUnwrap(decode(Fixtures.bankRecord(analysis: "<p><img src='//x.cn/a.png'></p>")))
        XCTAssertEqual(question.analysis, "<p><img src='https://x.cn/a.png'></p>")
    }

    func testParseJSONLDropsMalformedLines() {
        let text = [
            Fixtures.bankRecord("q1"),
            "this is not json",
            Fixtures.bankRecord("q2", subCategory: "实词辨析"),
            "", // blank line skipped
        ].joined(separator: "\n")
        let questions = BankLogic.parseJSONL(text)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions.map(\.id), ["q1", "q2"])
    }

    func testBankMetaDecodesCounts() throws {
        let json = #"{"version":1,"round":26,"counts":{"言语理解":500,"数字运算":700}}"#
        let meta = try JSONDecoder().decode(BankMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.round, 26)
        XCTAssertEqual(meta.counts?["言语理解"], 500)
        XCTAssertEqual(meta.totalCount, 1200)
    }

    func testBankMetaToleratesMissingFields() throws {
        let json = #"{"round":26}"#
        let meta = try JSONDecoder().decode(BankMeta.self, from: Data(json.utf8))
        XCTAssertNil(meta.counts)
        XCTAssertEqual(meta.totalCount, 0)
    }
}
