import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Route: Equatable {
        case login
        case examList
        case quiz(Exam)
        case result(ExamResult)
    }

    var route: Route = .login
    var theme: Theme
    var autoAdvanceOnCorrect: Bool {
        didSet {
            QuizSettings.saveAutoAdvanceOnCorrect(autoAdvanceOnCorrect)
        }
    }
    var notice: String?
    let api: APIClient

    init(api: APIClient = APIClient()) {
        self.api = api
        self.theme = Theme.load()
        self.autoAdvanceOnCorrect = QuizSettings.loadAutoAdvanceOnCorrect()
    }

    func start() async {
        route = api.hasSession ? .examList : .login
    }

    func toggleTheme() {
        theme = (theme == .light) ? .dark : .light
        theme.save()
    }

    /// Single funnel for errors: only session expiry / missing session force the
    /// login redirect; everything else is surfaced by the calling view model.
    func handle(_ error: Error) {
        guard let apiError = error as? APIError else { return }
        switch apiError {
        case .sessionExpired:
            api.clearSession()
            notice = "登录已过期，请重新登录"
            route = .login
        case .notLoggedIn:
            api.clearSession()
            notice = "登录已失效，请重新登录"
            route = .login
        default:
            break
        }
    }

    func logout() {
        api.clearSession()
        notice = nil
        route = .login
    }
}
