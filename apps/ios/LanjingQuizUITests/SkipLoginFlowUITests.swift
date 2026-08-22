import XCTest

/// 登录页「跳过」流程:未登录直接进入主界面并落在「我的」tab;Cookie 云端
/// 同步未开启时不显示配置输入框,开启后显示;「去登录」可回到登录页。
/// 与 PracticeFlowUITests 不同,本流程不启动 mock 上游——全程无登录请求;
/// 以未登录状态进入主界面后,考试列表与练习 tab 均显示「需要登录」占位
/// (去登录回登录页),不会因无会话请求被踢回登录页(正是跳过成立的前提)。
@MainActor
final class SkipLoginFlowUITests: XCTestCase {

    func testSkipLoginHidesCookieCloudFieldsUntilEnabled() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-reset-bank"]
        app.launch()

        let skip = app.buttons["skip-login"]
        if !skip.waitForExistence(timeout: 5) {
            // 模拟器残留了会话:先退出登录回到登录页,再验证跳过流程。
            let profileTab = app.tabBars.buttons["我的"]
            XCTAssertTrue(profileTab.waitForExistence(timeout: 10), "已登录状态下没有主界面 tab")
            profileTab.tap()
            app.buttons["退出登录"].tap()
            XCTAssertTrue(skip.waitForExistence(timeout: 10), "退出登录后跳过按钮未出现")
        }
        skip.tap()

        // 跳过 → 「我的」tab,显示「未登录」
        let notLoggedIn = app.staticTexts["未登录"]
        XCTAssertTrue(notLoggedIn.waitForExistence(timeout: 10), "跳过后未落在「我的」tab(未登录 label 缺失)")

        // 考试列表 tab:未登录应显示「需要登录」占位(与练习页一致),而不是
        // 网络错误文本/被踢回登录页。
        let examsTab = app.tabBars.buttons["考试列表"]
        XCTAssertTrue(examsTab.waitForExistence(timeout: 5), "考试列表 tab 缺失")
        examsTab.tap()
        XCTAssertTrue(app.staticTexts["需要登录"].waitForExistence(timeout: 5), "未登录时考试列表页缺少「需要登录」占位")
        XCTAssertTrue(app.buttons["去登录"].exists, "「需要登录」占位缺少去登录按钮")
        // 回到「我的」tab 继续后续断言
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(notLoggedIn.waitForExistence(timeout: 5), "回到「我的」tab 后未登录 label 缺失")

        // List 懒加载:先滚动到 Cookie 云端同步 Section 使其渲染,再断言输入框状态
        let toggle = app.switches["Cookie 云端同步"]
        var scrolls = 0
        while !toggle.exists && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Cookie 云端同步 toggle 缺失(滚动 \(scrolls) 次仍未找到)")

        let serverField = app.textFields["服务器地址"]
        let uuidField = app.textFields["UUID"]

        // 上次运行可能遗留开启状态(配置持久化):先归零再测
        if (toggle.value as? String) == "1" {
            setSwitch(toggle, to: "0")
            XCTAssertTrue(serverField.waitForNonExistence(timeout: 3), "关闭 toggle 后输入框应消失")
        }

        // 未开启:输入框不显示
        XCTAssertFalse(serverField.exists, "未开启时不应显示服务器地址输入框")
        XCTAssertFalse(uuidField.exists, "未开启时不应显示 UUID 输入框")

        // 开启 toggle → 输入框出现
        setSwitch(toggle, to: "1")
        let toggleValue = toggle.value as? String
        XCTAssertEqual(toggleValue, "1", "toggle 未切换(当前 value: \(toggleValue ?? "nil"))")
        XCTAssertTrue(serverField.waitForExistence(timeout: 5), "开启后服务器地址输入框未出现")
        XCTAssertTrue(uuidField.waitForExistence(timeout: 5), "开启后 UUID 输入框未出现")

        // 「去登录」回到登录页(账户 Section 在列表顶部,反向滚动)
        let goLogin = app.buttons["goto-login"]
        scrolls = 0
        while !goLogin.exists && scrolls < 6 {
            app.swipeDown()
            scrolls += 1
        }
        XCTAssertTrue(goLogin.waitForExistence(timeout: 5), "「去登录」按钮缺失")
        goLogin.tap()
        XCTAssertTrue(app.buttons["password-login-entry"].waitForExistence(timeout: 5), "「去登录」未回到登录页")
    }

    /// 不同 iOS 版本的 SwiftUI Toggle 行布局不同(开关位置、行可点击区域),
    /// 单一点击方式会在部分环境失效(Xcode 16/iOS 18 与新版模拟器行为
    /// 不一致)。依次尝试整行点击与多个开关位置坐标,直到 value 达到目标。
    private func setSwitch(_ toggle: XCUIElement, to target: String) {
        if (toggle.value as? String) == target { return }
        let attempts: [() -> Void] = [
            { toggle.tap() },
            { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() },
            { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() },
            { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() },
        ]
        for attempt in attempts {
            if (toggle.value as? String) == target { return }
            attempt()
        }
    }
}
