import Foundation

struct QuestionState: Identifiable, Equatable {
    enum State: String, Equatable {
        case right, error, unanswered
    }

    let questionsId: String
    let uuId: String?
    let num: Int
    let section: String
    var state: State
    var marked: Bool

    var id: String { questionsId }
}
