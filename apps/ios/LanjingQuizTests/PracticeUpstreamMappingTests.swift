import XCTest
@testable import LanjingQuiz

/// Practice mapping helpers (ports of apps/bank/lib/question-bank.js):
/// paper filtering, section cleaning, state join and DTO → BankQuestion.
final class PracticeUpstreamMappingTests: XCTestCase {

    // MARK: - matchCategory / isTargetExam

    func testMatchCategoryCoversAllFiveCategories() {
        XCTAssertEqual(PracticeMapping.matchCategory("【言语理解（二）】机考题库"), "言语理解")
        XCTAssertEqual(PracticeMapping.matchCategory("【数字运算（一）】机考题库"), "数字运算")
        XCTAssertEqual(PracticeMapping.matchCategory("【逻辑推理（三）】机考题库"), "逻辑推理")
        XCTAssertEqual(PracticeMapping.matchCategory("【资料分析（四）】机考题库"), "资料分析")
        XCTAssertEqual(PracticeMapping.matchCategory("【特有题型】机考题库"), "特有题型")
        XCTAssertNil(PracticeMapping.matchCategory("【常识判断】机考题库"))
    }

    func testIsTargetExamRequires机考题库StyleAndCategoryName() {
        let paper = Fixtures.makeExam(1, name: "【言语理解（二）】机考题库", style: "机考题库", wfs: 1)
        XCTAssertTrue(PracticeMapping.isTargetExam(paper))
        // wfs does not filter — it only selects the enter path.
        let inProgress = Fixtures.makeExam(2, name: "【言语理解（一）】机考题库", style: "机考题库", wfs: 0)
        XCTAssertTrue(PracticeMapping.isTargetExam(inProgress))
        // non-机考题库 style → excluded
        let mock = Fixtures.makeExam(3, name: "【言语理解（二）】机考题库", style: "中石化模考套餐")
        XCTAssertFalse(PracticeMapping.isTargetExam(mock))
        // non-target paper name → excluded
        let common = Fixtures.makeExam(4, name: "【常识判断】机考题库", style: "机考题库")
        XCTAssertFalse(PracticeMapping.isTargetExam(common))
    }

    // MARK: - cleanSection

    func testCleanSectionStripsPointCountSuffix() {
        XCTAssertEqual(PracticeMapping.cleanSection("逻辑填空(共200题,每题1分,合计200.0分)"), "逻辑填空")
        XCTAssertEqual(PracticeMapping.cleanSection("逻辑填空(共200题，每题1分，合计200.0分)"), "逻辑填空")
    }

    func testCleanSectionKeepsInformativeNotes() {
        XCTAssertEqual(PracticeMapping.cleanSection("长篇阅读（仅中国石油和国家管网考）"), "长篇阅读（仅中国石油和国家管网考）")
        XCTAssertEqual(PracticeMapping.cleanSection("物理题（往年仅中石化和中石油考）"), "物理题（往年仅中石化和中石油考）")
    }

    func testCleanSectionNormalizesWhitespaceAndEmpty() {
        XCTAssertEqual(PracticeMapping.cleanSection("  逻辑填空  "), "逻辑填空")
        XCTAssertEqual(PracticeMapping.cleanSection(""), "(无分类)")
        XCTAssertEqual(PracticeMapping.cleanSection("  "), "(无分类)")
    }

    // MARK: - join

    func testJoinMatchesByQuestionsId() {
        let questions = [
            Fixtures.questionDTO("q1"),
            Fixtures.questionDTO("q2"),
            Fixtures.questionDTO("q3"),
        ]
        let states = [
            Fixtures.makeQuestionState(questionsId: "q1", section: "逻辑填空"),
            Fixtures.makeQuestionState(questionsId: "q2", section: "语句表达"),
            Fixtures.makeQuestionState(questionsId: "q3", section: "逻辑填空"),
        ]
        let joined = PracticeMapping.join(questions: questions, states: states)
        XCTAssertEqual(joined.map(\.section), ["逻辑填空", "语句表达", "逻辑填空"])
    }

    func testJoinFallsBackPositionallyForMissingStates() {
        let questions = [
            Fixtures.questionDTO("q1"),
            Fixtures.questionDTO("q9"), // no state
            Fixtures.questionDTO("q3"),
        ]
        let states = [
            Fixtures.makeQuestionState(questionsId: "q1", section: "逻辑填空"),
            Fixtures.makeQuestionState(questionsId: "q2", section: "语句表达"),
            Fixtures.makeQuestionState(questionsId: "q3", section: "逻辑填空"),
        ]
        let joined = PracticeMapping.join(questions: questions, states: states)
        XCTAssertEqual(joined.map(\.section), ["逻辑填空", "语句表达", "逻辑填空"]) // q9 → positional state q2
    }

    func testJoinWithNoStatesGetsPlaceholderSection() {
        let joined = PracticeMapping.join(
            questions: [Fixtures.questionDTO("q1")],
            states: []
        )
        XCTAssertEqual(joined.map(\.section), ["(无分类)"])
    }

    func testJoinDuplicateIdsFirstWins() {
        let questions = [
            Fixtures.questionDTO("q1"),
            Fixtures.questionDTO("q1"),
        ]
        let states = [
            Fixtures.makeQuestionState(questionsId: "q1", section: "逻辑填空"),
            Fixtures.makeQuestionState(questionsId: "q1", section: "语句表达"),
        ]
        let joined = PracticeMapping.join(questions: questions, states: states)
        XCTAssertEqual(joined.map(\.section), ["逻辑填空", "逻辑填空"])
    }

    // MARK: - bankQuestion

    func testBankQuestionSingleAnswerFromKeyFlag() {
        let dto = Fixtures.questionDTO(
            "q1",
            question: "<p>1+1=?</p>",
            answers: ["<p>2</p>", "<p>3</p>", "<p>4</p>", "<p>5</p>"],
            keys: ["1", "0", "0", "0"],
            analysis: "<p>解析</p>"
        )
        let question = PracticeMapping.bankQuestion(
            dto: dto,
            section: "逻辑填空(共200题,每题1分,合计200.0分)",
            category: "言语理解",
            paperName: "【言语理解（二）】机考题库"
        )
        XCTAssertEqual(question.id, "q1")
        XCTAssertEqual(question.category, "言语理解")
        XCTAssertEqual(question.section, "逻辑填空")
        XCTAssertEqual(question.options, ["<p>2</p>", "<p>3</p>", "<p>4</p>", "<p>5</p>"])
        XCTAssertEqual(question.answer?.letters, ["A"])
        XCTAssertEqual(question.keys, [true, false, false, false])
        XCTAssertEqual(question.analysis, "<p>解析</p>")
        XCTAssertNil(question.stem) // ordinary questions carry no material
        XCTAssertEqual(question.sourceExamName, "【言语理解（二）】机考题库")
        XCTAssertNil(question.round)
        XCTAssertNil(question.collectedAt)
    }

    func testBankQuestionMapsCombParentInfoToStem() {
        let dto = Fixtures.questionDTO(
            "c1",
            question: "<p>小题</p>",
            parentInfo: "<p>共享材料</p>"
        )
        let question = PracticeMapping.bankQuestion(dto: dto, section: "文字资料(共15题,合计75.0分)", category: "资料分析", paperName: "p")
        XCTAssertEqual(question.stem, "<p>共享材料</p>")
        XCTAssertEqual(question.section, "文字资料")
    }

    func testBankQuestionMultiAnswerFromKeyFlags() {
        let dto = Fixtures.questionDTO(
            "q1",
            keys: ["1", "0", "1", "0"],
            testAnsRight: "D" // ignored — key flags win
        )
        let question = PracticeMapping.bankQuestion(dto: dto, section: "逻辑填空", category: "言语理解", paperName: "p")
        XCTAssertEqual(question.answer?.letters, ["A", "C"])
        XCTAssertTrue(question.isMulti)
    }

    func testBankQuestionFallsBackToTestAnsRight() {
        let dto = Fixtures.questionDTO(
            "q1",
            keys: ["0", "0", "0", "0"],
            testAnsRight: "D"
        )
        let question = PracticeMapping.bankQuestion(dto: dto, section: "逻辑填空", category: "言语理解", paperName: "p")
        XCTAssertEqual(question.answer?.letters, ["D"])
        XCTAssertTrue(question.isGradable)
    }

    func testBankQuestionUnknownAnswerIsNil() {
        let dto = Fixtures.questionDTO("q1", keys: ["0", "0", "0", "0"], testAnsRight: nil)
        let question = PracticeMapping.bankQuestion(dto: dto, section: "逻辑填空", category: "言语理解", paperName: "p")
        XCTAssertNil(question.answer)
        XCTAssertFalse(question.isGradable)
        XCTAssertEqual(question.keys, [false, false, false, false])
    }

    func testBankQuestionPreservesEmptyOptionSlots() {
        let dto = Fixtures.questionDTO(
            "q1",
            answers: ["<p>2</p>", nil, nil, "<p>5</p>"],
            keys: ["1", "0", "0", "0"]
        )
        let question = PracticeMapping.bankQuestion(dto: dto, section: "逻辑填空", category: "言语理解", paperName: "p")
        XCTAssertEqual(question.options, ["<p>2</p>", "", "", "<p>5</p>"])
        XCTAssertEqual(question.letters, ["A", "B", "C", "D"])
    }

    func testBankQuestionClassifiesSubCategory() {
        let dto = Fixtures.questionDTO(
            "q1",
            question: "<p>依次填入最恰当的一项是</p>",
            analysis: "<p>填入成语“栩栩如生”，形容非常逼真</p>"
        )
        let question = PracticeMapping.bankQuestion(dto: dto, section: "逻辑填空", category: "言语理解", paperName: "p")
        XCTAssertEqual(question.subCategory, "成语辨析")
    }

    func testBankQuestion特有题型SectionIsSubCategory() {
        let dto = Fixtures.questionDTO("q1", question: "<p>题干</p>")
        let question = PracticeMapping.bankQuestion(dto: dto, section: "时政", category: "特有题型", paperName: "【特有题型】机考题库")
        XCTAssertEqual(question.subCategory, "时政")
    }

    func testBankQuestionNormalizesImgSrcs() {
        let dto = Fixtures.questionDTO(
            "q1",
            question: "<p><img src=\"//fb.fbstatic.cn/1.png\"></p>"
        )
        let question = PracticeMapping.bankQuestion(dto: dto, section: "逻辑填空", category: "言语理解", paperName: "p")
        XCTAssertEqual(question.question, "<p><img src=\"https://fb.fbstatic.cn/1.png\"></p>")
    }
}
