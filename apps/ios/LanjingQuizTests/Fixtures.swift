import Foundation
@testable import LanjingQuiz

/// Canned exam_start HTML mirroring the structure the server parses:
/// section titles, answer-card anchors with question_cbox class states.
enum Fixtures {

    static let examStartHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <script>
    var exam_results_id = '87380582';
    var exam_info_id = '1439658';
    </script>
    </head>
    <body>
    <div class="exam-content">
      <div class="card-content-title">科技常识</div>
      <div class="card-content-list">
        <a href="#1">
          <div class="question_cbox right marked">
            <span>1</span><span questionsId="q1" uuId="u1"></span>
          </div>
        </a>
        <a href="#2">
          <div class="question_cbox error">
            <span>2</span><span questionsId="q2" uuId="u2"></span>
          </div>
        </a>
      </div>
      <div class="card-content-title">逻辑推理</div>
      <div class="card-content-list">
        <a href="#3">
          <div class="question_cbox">
            <span>3</span><span questionsId="q3"></span>
          </div>
        </a>
        <a href="#4">
          <div class="question_cbox right">
            <span>4</span><span questionsId="q4" uuId="u4"></span>
          </div>
        </a>
        <a href="#5">
          <div class="question_cbox right">
            <span>5</span><span questionsId="q1" uuId="u1"></span>
          </div>
        </a>
      </div>
    </div>
    </body>
    </html>
    """

    /// Same exam page but without section titles (single section → "(无分类)").
    static let examStartNoSectionsHTML = """
    <!DOCTYPE html>
    <html>
    <head><script>var exam_results_id = '999'; var exam_info_id = '888';</script></head>
    <body>
    <a href="#1">
      <div class="question_cbox right"><span>1</span><span questionsId="solo1" uuId="su1"></span></div>
    </a>
    </body>
    </html>
    """

    static let examStartMinimalHTML = """
    <!DOCTYPE html>
    <html><body><p>empty</p></body></html>
    """

    static func questionDTO(
        _ id: String = "q1",
        question: String = "<p>1+1=?</p>",
        answers: [String?] = ["<p>2</p>", "<p>3</p>", "<p>4</p>", "<p>5</p>"],
        keys: [String?] = ["1", "0", "0", "0"],
        testAns: String? = nil,
        testAnsRight: String? = nil,
        analysis: String? = nil
    ) -> QuestionDTO {
        QuestionDTO(
            _id: id,
            question: question,
            answer1: answers.count > 0 ? answers[0] : nil,
            answer2: answers.count > 1 ? answers[1] : nil,
            answer3: answers.count > 2 ? answers[2] : nil,
            answer4: answers.count > 3 ? answers[3] : nil,
            key1: keys.count > 0 ? keys[0] : nil,
            key2: keys.count > 1 ? keys[1] : nil,
            key3: keys.count > 2 ? keys[2] : nil,
            key4: keys.count > 3 ? keys[3] : nil,
            test_ans: testAns,
            test_ans_right: testAnsRight,
            analysis: analysis
        )
    }
}

// MARK: - Practice flow fixtures

extension Fixtures {

    /// StringValue has no memberwise init (custom decoder) — decode instead.
    private static func stringValue(_ raw: String) -> StringValue {
        try! JSONDecoder().decode(StringValue.self, from: Data("\"\(raw)\"".utf8))
    }

    /// Builds an Exam from a DTO (upstream ids are Int; wfs selects the enter path).
    static func makeExam(
        _ id: Int,
        name: String = "【言语理解（二）】机考题库",
        style: String = "机考题库",
        wfs: Int = 1
    ) -> Exam {
        Exam(
            dto: ExamListResponse.BizContent.ExamDTO(
                id: id,
                examName: name,
                examStyle: stringValue("0"),
                examStyleName: style,
                practiceMode: 2,
                examMode: "",
                examTime: 0,
                paperInfoId: nil,
                examTimesNum: nil,
                examTimesRestrict: nil,
                paid: nil,
                examTimeRestrict: nil,
                wfs: wfs,
                timeLeft: nil
            ),
            styleName: style
        )
    }

    static func makeQuestionState(
        questionsId: String,
        section: String = "逻辑填空",
        state: QuestionState.State = .unanswered,
        uuId: String? = "u1"
    ) -> QuestionState {
        QuestionState(questionsId: questionsId, uuId: uuId, num: 1, section: section, state: state, marked: false)
    }
}
