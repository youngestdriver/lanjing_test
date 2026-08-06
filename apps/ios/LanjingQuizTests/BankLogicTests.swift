import XCTest
@testable import LanjingQuiz

final class BankLogicTests: XCTestCase {

    private func questions(_ ids: [String], subCategory: String? = nil) -> [BankQuestion] {
        ids.enumerated().map { index, id in
            let line = Fixtures.bankRecord(id, subCategory: subCategory ?? "类\(index % 2)")
            return try! JSONDecoder().decode(BankQuestion.self, from: Data(line.utf8))
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

    private func makeQuestion(answer: Fixtures.BankAnswerSpec, isMulti: Bool = false) -> BankQuestion {
        try! JSONDecoder().decode(
            BankQuestion.self,
            from: Data(Fixtures.bankRecord(answer: answer).utf8)
        )
    }

    func testGradeSingleCorrect() {
        let question = makeQuestion(answer: .single("A"))
        XCTAssertEqual(BankLogic.grade(selected: ["A"], question: question), true)
    }

    func testGradeSingleWrong() {
        let question = makeQuestion(answer: .single("A"))
        XCTAssertEqual(BankLogic.grade(selected: ["B"], question: question), false)
    }

    func testGradeMultiExactSet() {
        let question = makeQuestion(answer: .multi(["A", "C"]))
        XCTAssertEqual(BankLogic.grade(selected: ["A", "C"], question: question), true)
        XCTAssertEqual(BankLogic.grade(selected: ["C", "A"], question: question), true) // order-insensitive
    }

    func testGradeMultiWrongSet() {
        let question = makeQuestion(answer: .multi(["A", "C"]))
        XCTAssertEqual(BankLogic.grade(selected: ["A"], question: question), false) // incomplete
        XCTAssertEqual(BankLogic.grade(selected: ["A", "B"], question: question), false) // wrong member
    }

    func testGradeUngradableReturnsNil() {
        let question = makeQuestion(answer: .none)
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

    // MARK: - BankSettings

    func testBankSettingsDefaultServerURL() {
        let suiteName = "BankLogicTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("no isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(BankSettings.loadServerURL(from: defaults), "http://127.0.0.1:3000")
        BankSettings.saveServerURL("http://192.168.1.5:3000", to: defaults)
        XCTAssertEqual(BankSettings.loadServerURL(from: defaults), "http://192.168.1.5:3000")
    }

    func testBaseURLValidation() {
        XCTAssertEqual(BankSettings.baseURL(from: "http://127.0.0.1:3000")?.absoluteString, "http://127.0.0.1:3000")
        XCTAssertEqual(BankSettings.baseURL(from: "http://127.0.0.1:3000/")?.absoluteString, "http://127.0.0.1:3000")
        XCTAssertEqual(BankSettings.baseURL(from: "  https://example.com/bank/  ")?.absoluteString, "https://example.com/bank")
        XCTAssertNil(BankSettings.baseURL(from: ""))
        XCTAssertNil(BankSettings.baseURL(from: "ftp://example.com"))
        XCTAssertNil(BankSettings.baseURL(from: "not a url"))
    }
}
