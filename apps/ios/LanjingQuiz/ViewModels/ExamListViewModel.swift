import Foundation
import Observation

@MainActor
@Observable
final class ExamListViewModel {
    var exams: [Exam] = []
    var grouped: [(style: String, exams: [Exam])] = []
    var isLoading = false
    var errorMessage: String?
    var needsLogin = false

    private let appState: AppState
    /// Exam IDs whose current server state has just been ended locally. A stale
    /// list response must not make an unusable "continue" record tappable again.
    private var suppressedExamStates: [Int: Int] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // 与练习页一致:未登录(登录页「跳过」进入主界面)时直接显示
        // 「需要登录」占位,不发起请求——无 sessionId 时上游会以登录页/重定向
        // 响应,旧实现只弹网络错误横幅,既占位又无去登录入口。
        guard appState.api.hasSession else {
            needsLogin = true
            exams = []
            grouped = []
            errorMessage = nil
            return
        }
        needsLogin = false
        do {
            let list = try await appState.api.examList()
            apply(list.exams)
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

    /// 放弃考试 (two-step confirmed in the UI): end the upstream attempt, immediately
    /// invalidate its current list state, then synchronize with the service.
    func abandon(_ exam: Exam) async {
        do {
            _ = try await appState.api.submitExam(examInfoId: String(exam.id), session: nil)
            suppressedExamStates[exam.id] = exam.wfs
            apply(exams)
            await load()
            // The upstream exam list can lag just behind exam_ending. Retry once so a
            // replacement "new exam" state appears without exposing the old attempt.
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch {
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = "放弃失败：\(apiError.message)"
            }
        }
    }

    private func apply(_ freshExams: [Exam]) {
        // Keep suppression only while the service returns the exact old state. If it
        // returns the same exam ID with a changed wfs value, that is a new valid state.
        suppressedExamStates = suppressedExamStates.filter { id, wfs in
            freshExams.contains { $0.id == id && $0.wfs == wfs }
        }
        let visibleExams = freshExams.filter { exam in
            suppressedExamStates[exam.id] != exam.wfs
        }
        exams = visibleExams
        grouped = Self.groupExams(visibleExams)
    }

    func logout() {
        appState.logout()
    }
}
