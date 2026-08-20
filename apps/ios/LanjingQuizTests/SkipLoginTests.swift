import XCTest
@testable import LanjingQuiz

/// 登录页「跳过」逻辑:绕过登录进入主界面,且未登录状态下的请求错误
/// (notLoggedIn)不再把用户踢回登录页——否则跳过形同虚设。会话过期
/// (sessionExpired)仍必须踢回。
final class SkipLoginTests: XCTestCase {

    @MainActor
    func testSkipLoginRoutesToExamList() {
        let appState = AppState()
        XCTAssertEqual(appState.route, .login)
        appState.skipLogin()
        XCTAssertEqual(appState.route, .examList)
    }

    @MainActor
    func testNotLoggedInKeepsCurrentRoute() {
        let appState = AppState()
        appState.route = .examList
        appState.handle(APIError.notLoggedIn)
        XCTAssertEqual(appState.route, .examList, "跳过登录后 notLoggedIn 不应再踢回登录页")
        XCTAssertNotNil(appState.notice, "应提示用户先登录")
    }

    @MainActor
    func testSessionExpiredStillRedirectsToLogin() {
        let appState = AppState()
        appState.route = .examList
        appState.handle(APIError.sessionExpired)
        XCTAssertEqual(appState.route, .login, "会话过期必须回到登录页")
        XCTAssertNotNil(appState.notice)
    }
}
