import XCTest
@testable import LanjingQuiz

@MainActor
final class ExamListViewModelTests: XCTestCase {

    /// 登录页「跳过」会以未登录状态进入主界面:此时考试列表 tab 应与练习页
    /// 一致——直接进入「需要登录」占位,不发起请求、不残留考试列表、不弹错误。
    /// (无 sessionId 时上游会返回登录页 HTML,旧实现会走 sessionExpired →
    /// 被踢回登录页,与「跳过」语义冲突。)
    func testLoadWithoutSessionShowsNeedsLogin() async throws {
        let appState = AppState()
        // 抹掉模拟器/Keychain 可能残留的会话,确保本次运行一定无 sessionId。
        appState.api.clearSession()
        let vm = ExamListViewModel(appState: appState)

        await vm.load()

        XCTAssertTrue(vm.needsLogin, "未登录时考试列表应进入「需要登录」占位")
        XCTAssertNil(vm.errorMessage, "「需要登录」占位不应显示错误信息")
        XCTAssertTrue(vm.exams.isEmpty, "「需要登录」占位下不应残留考试列表")
    }
}
