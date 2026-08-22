import XCTest
@testable import LanjingQuiz

@MainActor
final class AppStateTests: XCTestCase {

    /// 启动导入(检查 CookieCloud 云端会话,最长 4 秒)尚未结束时点了「跳过」:
    /// start() 导入完成后的路由决定不得覆盖用户的跳过选择。旧实现 start()
    /// 无条件 `route = hasSession ? .examList : .login`,无会话时会一条
    /// 路由写回 .login——用户刚进主界面就被踢回登录页。
    func testSkipDuringLaunchIsNotOverwrittenByStartRoute() async {
        let appState = AppState()
        // 模拟与本机残留会话无关的环境:清会话、卸载云端同步配置,
        // 让 pullAndApplyIfNeeded 走无网络路径(瞬时返回无会话)。
        appState.api.clearSession()
        CookieCloudSettings.saveConfig(.empty)

        appState.skipLogin()

        await appState.start()

        XCTAssertEqual(appState.route, .examList, "启动导入完成后不应覆盖「跳过」进入主界面的决定")
    }
}
