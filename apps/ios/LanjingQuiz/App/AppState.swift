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
    let cookieCloudSync: CookieCloudSync
    let bankClient: QuestionBankClient
    let bankStorage: BankStorage

    init(
        api: APIClient = APIClient(),
        bankClient: QuestionBankClient = QuestionBankClient(),
        bankStorage: BankStorage = FileManagerBankStorage()
    ) {
        self.api = api
        self.cookieCloudSync = CookieCloudSync(cookieStore: api.cookieStore)
        self.bankClient = bankClient
        self.bankStorage = bankStorage
        self.theme = Theme.load()
        self.autoAdvanceOnCorrect = QuizSettings.loadAutoAdvanceOnCorrect()
    }

    /// Launch path: import a cloud session (when CookieCloud sync is enabled)
    /// before deciding the route, so a fresh device with a cloud session
    /// lands on the exam list without logging in again.
    func start() async {
        let hasSession = await cookieCloudSync.pullAndApplyIfNeeded()
        route = hasSession ? .examList : .login
    }

    /// After a successful login: publish the new session to the cloud and
    /// route — never pull here, the fresh local session must win.
    func finishLogin() async {
        await cookieCloudSync.pushIfNeeded()
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
        api.logout()
        notice = nil
        route = .login
    }
}
