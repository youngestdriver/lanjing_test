import Foundation
import Observation

@MainActor
@Observable
final class ExamListViewModel {
    var exams: [Exam] = []
    var grouped: [(style: String, exams: [Exam])] = []
    var isLoading = false
    var errorMessage: String?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await appState.api.examList()
            exams = list.exams
            grouped = Self.groupExams(list.exams)
            errorMessage = nil
        } catch {
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = apiError.message
            }
        }
    }

    /// Port of renderExamList: drop 常识判断 exams, group by style,
    /// 机考题库 groups first, then alphabetical.
    static func groupExams(_ exams: [Exam]) -> [(style: String, exams: [Exam])] {
        let visible = exams.filter { !$0.name.contains("常识判断") }
        let byStyle = Dictionary(grouping: visible) { $0.style }
        let keys = byStyle.keys.sorted { a, b in
            let aIsJiti = a.contains("机考题库")
            let bIsJiti = b.contains("机考题库")
            if aIsJiti != bIsJiti { return aIsJiti }
            return a < b
        }
        return keys.map { ($0, byStyle[$0] ?? []) }
    }

    /// 放弃考试 (two-step confirmed in the UI): submit the exam upstream, then reload.
    func abandon(_ exam: Exam) async {
        do {
            _ = try await appState.api.submitExam(examInfoId: String(exam.id), session: nil)
            await load()
        } catch {
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = "放弃失败：\(apiError.message)"
            }
        }
    }

    func logout() {
        appState.logout()
    }
}
