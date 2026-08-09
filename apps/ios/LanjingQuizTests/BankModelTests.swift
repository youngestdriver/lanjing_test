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
            stem: nil,
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

    // MARK: - JSONL persistence (crawl → store → read back)

    private func roundTrip(_ question: BankQuestion) throws -> BankQuestion {
        let encoder = JSONEncoder()
        let data = try encoder.encode(question)
        return try JSONDecoder().decode(BankQuestion.self, from: data)
    }

    func testEncodeDecodeRoundTripPreservesFields() throws {
        let original = makeQuestion()
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "b1")
        XCTAssertEqual(decoded.category, "言语理解")
        XCTAssertEqual(decoded.section, "逻辑填空")
        XCTAssertEqual(decoded.subCategory, "成语辨析")
        XCTAssertEqual(decoded.answer?.letters, ["A"])
        XCTAssertEqual(decoded.sourceExamName, "【言语理解（二）】机考题库")
        XCTAssertNil(decoded.round) // crawled records have no collector metadata
    }

    func testEncodeAnswerSingleLetterAsStringMultiAsArray() throws {
        let encoder = JSONEncoder()
        // single → "A" (collector-compatible string form)
        let single = try encoder.encode(makeQuestion(answer: .init(letters: ["A"])))
        XCTAssertTrue(String(data: single, encoding: .utf8)!.contains("\"answer\":\"A\""))
        // multi → ["A","C"]
        let multi = try encoder.encode(makeQuestion(answer: .init(letters: ["A", "C"])))
        XCTAssertTrue(String(data: multi, encoding: .utf8)!.contains("\"answer\":[\"A\",\"C\"]"))
        // nil → key omitted (synthesized encodeIfPresent); decoding tolerates
        // both omission and the collector's explicit "answer":null.
        let none = try encoder.encode(makeQuestion(answer: nil))
        let noneJSON = String(data: none, encoding: .utf8)!
        XCTAssertFalse(noneJSON.contains("\"answer\""))
        XCTAssertNoThrow(try JSONDecoder().decode(BankQuestion.self, from: none))
    }

    func testDecodesCollectorFormatLine() throws {
        // A hand-written line in apps/bank/data format (round/collectedAt
        // present, answer as array).
        let line = """
        {"_id":"q9","category":"言语理解","section":"逻辑填空","subCategory":"成语辨析",\
        "question":"<p>题干</p>","options":["<p>A</p>","","",""],\
        "answer":["A","C"],"analysis":"<p>解析</p>","sourceExamName":"【言语理解（二）】机考题库",\
        "round":4,"collectedAt":"2026-08-07T00:00:00.000Z"}
        """
        let question = try JSONDecoder().decode(BankQuestion.self, from: Data(line.utf8))
        XCTAssertEqual(question.id, "q9")
        XCTAssertEqual(question.options, ["<p>A</p>", "", "", ""])
        XCTAssertEqual(question.answer?.letters, ["A", "C"])
        XCTAssertTrue(question.isMulti)
        XCTAssertEqual(question.round, 4)
        // records crawled before stems were stored have no stem key
        XCTAssertNil(question.stem)
    }

    func testDecodesCombRecordWithStem() throws {
        let line = """
        {"_id":"c1","category":"资料分析","section":"文字资料","subCategory":"其他",\
        "question":"<p>小题</p>","stem":"<p>共享材料</p>","options":["<p>A</p>","","",""],\
        "answer":"A","analysis":"","sourceExamName":"【资料分析（一）】机考题库",\
        "round":1,"collectedAt":"2026-08-07T00:00:00.000Z"}
        """
        let question = try JSONDecoder().decode(BankQuestion.self, from: Data(line.utf8))
        XCTAssertEqual(question.stem, "<p>共享材料</p>")
        // round-trip preserves the stem
        let roundTripped = try roundTrip(question)
        XCTAssertEqual(roundTripped.stem, "<p>共享材料</p>")
    }
}
