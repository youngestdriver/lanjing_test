import Foundation

struct QuestionState: Identifiable, Equatable {
    enum State: String, Equatable {
        case right, error, unanswered
    }

    let questionsId: String
    let uuId: String?
    /// Raw answer-card number: "1.1" for comb (资料分析) sub-questions, plain
    /// "3" for ordinary questions. Displayed verbatim in the badge/answer card.
    let num: String
    /// Comb (资料分析) group id from the insert-list wrapper; nil for ordinary
    /// questions. Passed to /exam/get_question_info/ to fetch the shared stem.
    let combId: String?
    let section: String
    var state: State
    var marked: Bool

    var id: String { questionsId }
}
