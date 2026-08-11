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
    let bankStorage: BankStorage
    /// Practice-run persistence (Application Support/LanjingQuiz/
    /// practice-session.json), injected like bankStorage so tests can fake it.
    let practiceSessionStore: FileManagerPracticeSessionStore
    /// Bumped whenever the local bank is deleted (我的 > 删除题库) so every
    /// PracticeBankViewModel instance (练习 tab and 我的 tab create their own)
    /// resets and re-crawls on its next appearance.
    private(set) var bankResetVersion = 0

    init(api: APIClient = APIClient(), bankStorage: BankStorage = FileManagerBankStorage(),
         practiceSessionStore: FileManagerPracticeSessionStore = FileManagerPracticeSessionStore()) {
        self.api = api
        self.cookieCloudSync = CookieCloudSync(cookieStore: api.cookieStore)
        self.bankStorage = bankStorage
        self.practiceSessionStore = practiceSessionStore
        self.theme = Theme.load()
        self.autoAdvanceOnCorrect = QuizSettings.loadAutoAdvanceOnCorrect()
    }

    /// Launch path: import a cloud session (when CookieCloud sync is enabled)
    /// before deciding the route, so a fresh device with a cloud session
    /// lands on the exam list without logging in again.
    func start() async {
        #if DEBUG
        // UI-testing hook: wipe the local bank so the practice crawl runs
        // deterministically on every test execution (the argument is never
        // passed in production builds).
        if ProcessInfo.processInfo.arguments.contains("-reset-bank") {
            try? bankStorage.removeAll()
            // Also drop any persisted practice run: otherwise a stale archive
            // from the previous test execution resumes at question 2/3 and
            // breaks "第 1/" assertions.
            try? await practiceSessionStore.clear()
        }
        #endif
        let hasSession = await cookieCloudSync.pullAndApplyIfNeeded()
        route = hasSession ? .examList : .login
    }

    /// After a successful login: publish the new session to the cloud and
    /// route — never pull here, the fresh local session must win.
    func finishLogin() async {
        await cookieCloudSync.pushIfNeeded()
        route = api.hasSession ? .examList : .login
    }

    /// 我的 > 外观 > 跟随系统颜色设置. Turning it on remembers the current
    /// manual light/dark choice (restored when turned off); off restores it.
    func setFollowsSystem(_ follows: Bool) {
        if follows {
            if theme != .system { Theme.saveManual(theme) }
            theme = .system
        } else {
            theme = Theme.loadManual()
        }
        theme.save()
    }

    func toggleTheme() {
        // Quiz-header quick flip: light ↔ dark; tapping while following the
        // system switches to a fixed dark theme (exits follow-system).
        theme = theme == .dark ? .light : .dark
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

    /// Wipe the local question bank (我的 > 题库 > 删除题库). Also clears the
    /// crawl log (it lives in the bank dir) and the persisted practice
    /// session; re-entering the practice tab re-crawls everything from
    /// scratch. (PracticeBankViewModel.bankWasDeleted clears the session file
    /// too — double insurance.)
    func deleteBank() {
        try? bankStorage.removeAll()
        bankResetVersion += 1
        notice = "题库已删除，重新进入练习页会重新爬取全部试卷"
        Task { try? await practiceSessionStore.clear() }
    }
}
