import XCTest
@testable import LanjingQuiz

final class AnswerMappingTests: XCTestCase {

    func testSingleCorrectAnswer() {
        let question = Question(dto: Fixtures.questionDTO(keys: ["1", "0", "0", "0"]))
        XCTAssertEqual(question.correctAnswers, ["A"])
        XCTAssertFalse(question.isMulti)
        XCTAssertEqual(question.firstAnswer, "A")
        XCTAssertEqual(question.letters, ["A", "B", "C", "D"])
        XCTAssertTrue(question.isCorrectAnswer("A"))
        XCTAssertFalse(question.isCorrectAnswer("B"))
    }

    func testMultiCorrectAnswers() {
        let question = Question(dto: Fixtures.questionDTO(keys: ["1", "0", "1", "0"]))
        XCTAssertEqual(question.correctAnswers, ["A", "C"])
        XCTAssertTrue(question.isMulti)
        XCTAssertEqual(question.firstAnswer, "A")
    }

    func testNoKeysFallsBackToTestAnsRight() {
        let withFallback = Question(dto: Fixtures.questionDTO(keys: ["0", "0", "0", "0"], testAnsRight: "B"))
        XCTAssertEqual(withFallback.correctAnswers, [])
        XCTAssertFalse(withFallback.isMulti)
        XCTAssertEqual(withFallback.firstAnswer, "B")

        let withoutFallback = Question(dto: Fixtures.questionDTO(keys: ["0", "0", "0", "0"]))
        XCTAssertEqual(withoutFallback.firstAnswer, "?")
    }

    func testPreviousAnswersDecodeUpstreamKeyList() {
        let question = Question(dto: Fixtures.questionDTO(
            keys: ["0", "0", "1", "0"],
            testAns: "key3,"
        ))
        XCTAssertEqual(question.previousAnswers, ["C"])

        let multi = Question(dto: Fixtures.questionDTO(
            keys: ["1", "0", "1", "0"],
            testAns: "key1,key3,"
        ))
        XCTAssertEqual(multi.previousAnswers, ["A", "C"])
    }

    func testAnswerHtmlJoinsWithBreak() {
        let question = Question(dto: Fixtures.questionDTO(keys: ["1", "0", "1", "0"]))
        XCTAssertEqual(question.answerHtml, "<p>2</p><br><p>4</p>")
    }

    func testAnswerKeyMapping() {
        XCTAssertEqual(Question.answerKey(for: "A"), "key1,")
        XCTAssertEqual(Question.answerKey(for: "B"), "key2,")
        XCTAssertEqual(Question.answerKey(for: "C"), "key3,")
        XCTAssertEqual(Question.answerKey(for: "D"), "key4,")
        XCTAssertNil(Question.answerKey(for: "E"))
    }

    func testCompactLayoutDetection() {
        let compact = Question(dto: Fixtures.questionDTO(answers: ["对", "错", "对", "错"]))
        XCTAssertTrue(compact.isCompactLayout)

        let threeOptions = Question(dto: Fixtures.questionDTO(answers: ["对", "错", "对"]))
        XCTAssertFalse(threeOptions.isCompactLayout)

        let longOption = Question(dto: Fixtures.questionDTO(answers: ["对", "错", "不正确", "错"]))
        XCTAssertFalse(longOption.isCompactLayout)
    }

    func testCompactLayoutExcludesImageOptions() {
        let imageOptions = Question(dto: Fixtures.questionDTO(answers: [
            #"<img src="/a.png">"#, #"<img src="/b.png">"#,
            #"<img src="/c.png">"#, #"<img src="/d.png">"#,
        ]))
        XCTAssertFalse(imageOptions.isCompactLayout)
        XCTAssertTrue(imageOptions.isImageOptions)

        let textOptions = Question(dto: Fixtures.questionDTO(
            answers: ["<p>苹果汁</p>", "<p>香蕉汁</p>", "<p>橘子汁</p>", "<p>葡萄汁</p>"]
        ))
        XCTAssertFalse(textOptions.isImageOptions)

        let mixed = Question(dto: Fixtures.questionDTO(answers: [
            "<p>文字</p>", #"<img src="/b.png">"#, "<p>文字</p>", #"<img src="/d.png">"#,
        ]))
        XCTAssertFalse(mixed.isImageOptions)

        // Logic layout: compact short-text tiles and image options both pin at bottom
        let compact = Question(dto: Fixtures.questionDTO(answers: ["对", "错", "对", "错"]))
        // Short textual choices are still regular vertically stacked options.
        XCTAssertFalse(compact.isLogicLayout)
        XCTAssertTrue(imageOptions.isLogicLayout)
        XCTAssertFalse(textOptions.isLogicLayout)
        XCTAssertFalse(mixed.isLogicLayout)
    }

    func testMultiSelectionCorrectness() {
        XCTAssertTrue(QuizLogic.isMultiSelectionCorrect(selected: ["A", "C"], correct: ["A", "C"]))
        XCTAssertFalse(QuizLogic.isMultiSelectionCorrect(selected: ["A"], correct: ["A", "C"]))
        XCTAssertFalse(QuizLogic.isMultiSelectionCorrect(selected: [], correct: ["A"]))
        XCTAssertFalse(QuizLogic.isMultiSelectionCorrect(selected: ["B"], correct: ["A", "C"]))
    }

    func testAnswerCountMapping() {
        let question = Question(dto: Fixtures.questionDTO(answers: ["<p>2</p>", "<p>3</p>"]))
        XCTAssertEqual(question.letters, ["A", "B"])
        XCTAssertEqual(question.answers.count, 2)
    }
}
