import XCTest
@testable import LanjingQuiz

final class QuizLogicTests: XCTestCase {

    private func states(_ values: [QuestionState.State]) -> [QuestionState] {
        values.enumerated().map { index, state in
            QuestionState(
                questionsId: "q\(index)",
                uuId: nil,
                num: index + 1,
                section: "",
                state: state,
                marked: false
            )
        }
    }

    func testNextIndexSkipsToUnanswered() {
        let s = states([.right, .unanswered, .unanswered])
        XCTAssertEqual(QuizLogic.nextIndex(after: 0, states: s), 1)
        XCTAssertEqual(QuizLogic.nextIndex(after: 1, states: s), 2)
    }

    func testNextIndexWrapsAround() {
        let s = states([.unanswered, .right])
        XCTAssertEqual(QuizLogic.nextIndex(after: 1, states: s), 0)
    }

    func testNextIndexFallsBackToNextIndexWhenAllAnswered() {
        let s = states([.right, .right])
        XCTAssertEqual(QuizLogic.nextIndex(after: 0, states: s), 1)
        XCTAssertEqual(QuizLogic.nextIndex(after: 1, states: s), 1)
    }

    func testNextIndexEmptyStates() {
        XCTAssertEqual(QuizLogic.nextIndex(after: 0, states: []), 0)
    }

    func testOptionResultMarksOnlyReferenceAndSelectedWrongOptions() {
        // Correct single-choice submission: only the reference option is ✅.
        XCTAssertEqual(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: true,
                isCorrect: true,
                isMulti: false,
                questionState: .right
            ),
            .correct
        )
        XCTAssertNil(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: false,
                isCorrect: false,
                isMulti: false,
                questionState: .right
            )
        )

        // Wrong single-choice submission: selected option is ❌, reference is ✅,
        // and untouched options keep their letters.
        XCTAssertEqual(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: true,
                isCorrect: false,
                isMulti: false,
                questionState: .error
            ),
            .wrong
        )
        XCTAssertEqual(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: false,
                isCorrect: true,
                isMulti: false,
                questionState: .error
            ),
            .correct
        )
        XCTAssertNil(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: false,
                isCorrect: false,
                isMulti: false,
                questionState: .error
            )
        )

        // A multi-choice result can contain both a selected reference and a
        // selected wrong option.
        XCTAssertEqual(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: true,
                isCorrect: true,
                isMulti: true,
                questionState: .error
            ),
            .correct
        )
        XCTAssertEqual(
            QuizLogic.optionResult(
                isAnswered: true,
                isSelected: true,
                isCorrect: false,
                isMulti: true,
                questionState: .error
            ),
            .wrong
        )
    }

    func testMMSSFormatting() {
        XCTAssertEqual(Formatters.mmss(0), "00:00")
        XCTAssertEqual(Formatters.mmss(1), "00:01")
        XCTAssertEqual(Formatters.mmss(59), "00:59")
        XCTAssertEqual(Formatters.mmss(60), "01:00")
        XCTAssertEqual(Formatters.mmss(61), "01:01")
        XCTAssertEqual(Formatters.mmss(600), "10:00")
    }

    func testSectionTabShortLabel() {
        XCTAssertEqual(SectionTabsView.shortLabel("科技常识(单选)"), "科技常识")
        XCTAssertEqual(SectionTabsView.shortLabel("无括号标题"), "无括号标题")
        XCTAssertEqual(SectionTabsView.shortLabel("(以括号开头)"), "")
    }
}
