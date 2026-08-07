import XCTest
@testable import LanjingQuiz

final class BankLogicTests: XCTestCase {

    private func makeQuestion(
        _ id: String,
        subCategory: String = "类",
        answer: BankQuestion.Answer? = BankQuestion.Answer(letters: ["A"])
    ) -> BankQuestion {
        BankQuestion(
            id: id,
            category: "言语理解",
            section: "逻辑填空",
            subCategory: subCategory,
            question: "<p>题干</p>",
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
}
