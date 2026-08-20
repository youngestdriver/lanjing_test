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
    /// 练习进度注册表(Application Support/LanjingQuiz/practice-progress.json),
    /// 与 sessionStore 同注入模式。
    let practiceProgressStore: FileManagerPracticeProgressStore
    /// Bumped whenever the local bank is deleted (我的 > 删除题库) so every
    /// PracticeBankViewModel instance (练习 tab and 我的 tab create their own)
    /// resets and re-crawls on its next appearance.
    private(set) var bankResetVersion = 0

    init(api: APIClient = APIClient(), bankStorage: BankStorage = FileManagerBankStorage(),
         practiceSessionStore: FileManagerPracticeSessionStore = FileManagerPracticeSessionStore(),
         practiceProgressStore: FileManagerPracticeProgressStore = FileManagerPracticeProgressStore()) {
        self.api = api
        self.cookieCloudSync = CookieCloudSync(cookieStore: api.cookieStore)
        self.bankStorage = bankStorage
        self.practiceSessionStore = practiceSessionStore
        self.practiceProgressStore = practiceProgressStore
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
            // 进度注册表同样清零:入口行回到纯 "N 题" 基线(UI 测试断言)。
            try? await practiceProgressStore.clear()
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

    /// 登录页「跳过」:绕过登录直接进入主界面。不持久化——重启后仍由
    /// start() 决定路由(已配置 CookieCloud 且有云端会话时自动进入主界面,
    /// 否则回到登录页)。未登录状态下考试/练习页会提示先登录,「我的」页
    /// 可配置 Cookie 云端同步并回到登录页。
    func skipLogin() {
        route = .examList
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
            // 清会话但不强制踢回登录页:登录页「跳过」会以未登录状态进入
            // 主界面(先配置 Cookie 云端同步再登录),此时任何请求都会得到
            // notLoggedIn——踢回会让跳过形同虚设。已登录用户登录失效时
            // 同样只会看到提示,不会被自动弹回。
            api.clearSession()
            notice = "请先登录，可在「我的」页配置登录信息"
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
        Task { try? await practiceProgressStore.clear() }
    }
}
