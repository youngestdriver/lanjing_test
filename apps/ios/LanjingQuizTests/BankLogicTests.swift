import XCTest
@testable import LanjingQuiz

final class BankLogicTests: XCTestCase {

    private func makeQuestion(
        _ id: String,
        subCategory: String = "类",
        answer: BankQuestion.Answer? = BankQuestion.Answer(letters: ["A"]),
        stem: String? = nil
    ) -> BankQuestion {
        BankQuestion(
            id: id,
            category: "言语理解",
            section: "逻辑填空",
            subCategory: subCategory,
            question: "<p>题干</p>",
            stem: stem,
            options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"],
            answer: answer,
            analysis: nil,
            sourceExamName: nil,
            round: nil,
            collectedAt: nil
        )
    }

    private func questions(_ ids: [String], subCategory: String? = nil) -> [BankQuestion] {
        ids.enumerated().map { index, id in
            makeQuestion(id, subCategory: subCategory ?? "类\(index % 2)")
        }
    }

    // MARK: - grouping

    func testGroupBySubcategoryPreservesFirstAppearanceOrder() {
        let groups = BankLogic.groupBySubcategory(questions(["q1", "q2", "q3", "q4", "q5"]))
        XCTAssertEqual(groups.map(\.name), ["类0", "类1"])
        XCTAssertEqual(groups[0].questions.map(\.id), ["q1", "q3", "q5"])
        XCTAssertEqual(groups[1].questions.map(\.id), ["q2", "q4"])
    }

    func testGroupBySubcategoryFallsBackForEmptyName() {
        let groups = BankLogic.groupBySubcategory(questions(["q1"], subCategory: ""))
        XCTAssertEqual(groups.map(\.name), ["未分类"])
    }

    // MARK: - parseJSONL

    func testParseJSONLDropsMalformedLines() throws {
        let encoder = JSONEncoder()
        let q1 = try encoder.encode(makeQuestion("q1"))
        let q2 = try encoder.encode(makeQuestion("q2", subCategory: "实词辨析"))
        let text = [
            String(data: q1, encoding: .utf8)!,
            "this is not json",
            String(data: q2, encoding: .utf8)!,
            "", // blank line skipped
        ].joined(separator: "\n")
        let questions = BankLogic.parseJSONL(text)
        XCTAssertEqual(questions.map(\.id), ["q1", "q2"])
    }

    // MARK: - grading

    func testGradeSingleCorrect() {
        let question = makeQuestion("q1", answer: .init(letters: ["A"]))
        XCTAssertEqual(BankLogic.grade(selected: ["A"], question: question), true)
    }

    func testGradeSingleWrong() {
        let question = makeQuestion("q1", answer: .init(letters: ["A"]))
        XCTAssertEqual(BankLogic.grade(selected: ["B"], question: question), false)
    }

    func testGradeMultiExactSet() {
        let question = makeQuestion("q1", answer: .init(letters: ["A", "C"]))
        XCTAssertEqual(BankLogic.grade(selected: ["A", "C"], question: question), true)
        XCTAssertEqual(BankLogic.grade(selected: ["C", "A"], question: question), true) // order-insensitive
    }

    func testGradeMultiWrongSet() {
        let question = makeQuestion("q1", answer: .init(letters: ["A", "C"]))
        XCTAssertEqual(BankLogic.grade(selected: ["A"], question: question), false) // incomplete
        XCTAssertEqual(BankLogic.grade(selected: ["A", "B"], question: question), false) // wrong member
    }

    func testGradeUngradableReturnsNil() {
        let question = makeQuestion("q1", answer: nil)
        XCTAssertNil(BankLogic.grade(selected: ["A"], question: question))
    }

    // MARK: - optionResult

    func testOptionResultMarkers() {
        XCTAssertNil(BankLogic.optionResult(isAnswered: false, isSelected: true, isCorrect: true))
        XCTAssertEqual(BankLogic.optionResult(isAnswered: true, isSelected: true, isCorrect: false), .wrong)
        XCTAssertEqual(BankLogic.optionResult(isAnswered: true, isSelected: false, isCorrect: true), .correct)
        XCTAssertNil(BankLogic.optionResult(isAnswered: true, isSelected: false, isCorrect: false))
    }

    // MARK: - shuffle

    func testShuffledIsDeterministicForSameSeed() {
        let source = questions(Array(0..<30).map { "q\($0)" }, subCategory: "类")
        let a = BankLogic.shuffled(source, seed: 42)
        let b = BankLogic.shuffled(source, seed: 42)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    func testShuffledPermutesForDifferentSeed() {
        let source = questions(Array(0..<30).map { "q\($0)" }, subCategory: "类")
        let a = BankLogic.shuffled(source, seed: 1)
        let b = BankLogic.shuffled(source, seed: 2)
        XCTAssertNotEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(Set(a.map(\.id)), Set(source.map(\.id))) // same members
    }

    // MARK: - group-preserving shuffle (资料分析 comb 大序号)

    func testShuffledKeepingGroupsKeepsSameStemAdjacent() {
        let source = [
            makeQuestion("n1", stem: nil),
            makeQuestion("a1", stem: "<p>材料A</p>"),
            makeQuestion("a2", stem: "<p>材料A</p>"),
            makeQuestion("n2", stem: nil),
            makeQuestion("b1", stem: "<p>材料B</p>"),
            makeQuestion("a3", stem: "<p>材料A</p>"),
        ]
        let shuffled = BankLogic.shuffledKeepingGroups(source, seed: 7)
        XCTAssertEqual(Set(shuffled.map(\.id)), Set(source.map(\.id))) // same members
        // 大序号 group members must stay adjacent (both orders allowed).
        let positions = Dictionary(uniqueKeysWithValues: shuffled.enumerated().map { ($1.id, $0) })
        for group in [["a1", "a2", "a3"], ["b1"]] {
            let indexes = group.map { positions[$0]! }.sorted()
            XCTAssertEqual(indexes, Array(indexes[0]..<(indexes[0] + group.count)), "\(group) split apart")
        }
    }

    func testShuffledKeepingGroupsPreservesIntraGroupOrder() {
        let source = [
            makeQuestion("a1", stem: "<p>材料A</p>"),
            makeQuestion("a2", stem: "<p>材料A</p>"),
            makeQuestion("b1", stem: "<p>材料B</p>"),
            makeQuestion("a3", stem: "<p>材料A</p>"),
            makeQuestion("b2", stem: "<p>材料B</p>"),
        ]
        for seed: UInt64 in [1, 2, 3, 7, 42] {
            let shuffled = BankLogic.shuffledKeepingGroups(source, seed: seed)
            let aIds = shuffled.filter { $0.stem == "<p>材料A</p>" }.map(\.id)
            let bIds = shuffled.filter { $0.stem == "<p>材料B</p>" }.map(\.id)
            XCTAssertEqual(aIds, ["a1", "a2", "a3"])
            XCTAssertEqual(bIds, ["b1", "b2"])
        }
    }

    func testShuffledKeepingGroupsIsDeterministicForSameSeed() {
        let source = [
            makeQuestion("n1"),
            makeQuestion("a1", stem: "<p>材料A</p>"),
            makeQuestion("a2", stem: "<p>材料A</p>"),
            makeQuestion("n2"),
            makeQuestion("b1", stem: "<p>材料B</p>"),
            makeQuestion("a3", stem: "<p>材料A</p>"),
        ]
        let a = BankLogic.shuffledKeepingGroups(source, seed: 42)
        let b = BankLogic.shuffledKeepingGroups(source, seed: 42)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    func testShuffledKeepingGroupsWithoutStemsIsAPlainShuffle() {
        let source = questions(Array(0..<20).map { "q\($0)" }, subCategory: "类")
        let shuffled = BankLogic.shuffledKeepingGroups(source, seed: 9)
        XCTAssertEqual(Set(shuffled.map(\.id)), Set(source.map(\.id)))
        XCTAssertNotEqual(shuffled.map(\.id), source.map(\.id)) // actually permuted
    }

    // MARK: - 日志导出

    private func makeLogEntry(
        step: PracticeUpstreamClient.CrawlLogEntry.Step = .enter,
        outcome: PracticeUpstreamClient.CrawlLogEntry.Outcome = .success,
        paperName: String = "【言语理解（二）】机考题库",
        message: String? = nil
    ) -> PracticeUpstreamClient.CrawlLogEntry {
        PracticeUpstreamClient.CrawlLogEntry(
            timestamp: "2026-08-10T00:10:00Z",
            paperId: "E1",
            paperName: paperName,
            step: step,
            outcome: outcome,
            message: message
        )
    }

    func testExportLogTextSummarizesAndListsSteps() {
        let entries = [
            makeLogEntry(step: .paperList, paperName: "全部试卷", message: "共 12 份试卷"),
            makeLogEntry(outcome: .success, message: "200 题"),
            makeLogEntry(step: .save, outcome: .success, message: "200 题"),
            makeLogEntry(step: .enter, outcome: .failure, message: "登录已过期，请重新登录"),
            makeLogEntry(step: .skip, outcome: .skipped, message: "已爬取，跳过"),
        ]
        let text = BankLogic.exportLogText(entries)

        XCTAssertTrue(text.contains("题库爬取日志（共 5 条）"))
        XCTAssertTrue(text.contains("成功 3 · 失败 1 · 跳过 1"))
        XCTAssertTrue(text.contains("【言语理解（二）】机考题库 · 进入试卷 — 成功（200 题）"))
        XCTAssertTrue(text.contains("【言语理解（二）】机考题库 · 保存题目 — 成功（200 题）"))
        XCTAssertTrue(text.contains("【言语理解（二）】机考题库 · 进入试卷 — 失败（登录已过期，请重新登录）"))
        XCTAssertTrue(text.contains("【言语理解（二）】机考题库 · 跳过 — 跳过（已爬取，跳过）"))
        XCTAssertTrue(text.contains("全部试卷 · 获取试卷列表 — 成功（共 12 份试卷）"))
        // ISO8601 timestamps are rendered in local display time (UTC → local)
        let iso = ISO8601DateFormatter().date(from: "2026-08-10T00:10:00Z")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertTrue(text.contains("[\(formatter.string(from: iso))]"))
    }

    func testExportLogTextHandlesEmptyLog() {
        XCTAssertEqual(BankLogic.exportLogText([]), "题库爬取日志（共 0 条）\n成功 0 · 失败 0 · 跳过 0\n")
    }

    func testExportFileNameUsesDateTime() throws {
        // Local time: the filename is user-facing (my device's clock).
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 14, minute: 30))!
        XCTAssertEqual(BankLogic.exportFileName(from: date), "爬取日志_20260810_1430.txt")
    }
}
