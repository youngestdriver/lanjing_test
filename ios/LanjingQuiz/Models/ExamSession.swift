import Foundation

/// Result of entering an exam: parsed answer-card states, IDs and per-section stats
/// (server.js /api/exams/:id/enter response).
struct ExamSession: Equatable {
    let examInfoId: String
    let examResultsId: String
    let uuid: String?
    let questionStates: [QuestionState]
    let sectionMap: [String: SectionStats]
    let sectionOrder: [String]

    var testIds: [String] { questionStates.map(\.questionsId) }
}
