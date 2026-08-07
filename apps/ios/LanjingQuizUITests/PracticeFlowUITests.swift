import XCTest

/// Exercises the practice flow end-to-end against an in-process mock
/// upstream (LANJING_BASE_URL launch env) — login → 练习 → 分类 → 试卷 →
/// 题型 → 答题 → 完成, then asserts the best-effort attempt end fired.
/// Hermetic: runs in CI without any local server.
///
/// Setup happens inline in the test method (not in setUp/tearDown): those
/// lifecycle overrides are nonisolated on older XCTest SDKs, which would
/// make touching @MainActor properties a compile error there.
@MainActor
final class PracticeFlowUITests: XCTestCase {

    func testPracticeFlowLoadsQuestions() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launch()
        logInIfNeeded(app)

        // Practice tab → category list (paper counts come from the mock list).
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 10), "练习 tab missing")
        practiceTab.tap()

        let categoryRow = app.staticTexts["言语理解"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 10), "category list never appeared")
        categoryRow.tap()

        // Paper list — both 机考题库 papers visible, non-target paper filtered.
        let paperRow = app.staticTexts["【言语理解（二）】机考题库"]
        XCTAssertTrue(paperRow.waitForExistence(timeout: 10), "paper list is blank — no rows appeared")
        XCTAssertFalse(app.staticTexts["【中国石化模拟卷（四）】"].exists, "non-target paper must be filtered out")
        paperRow.tap()

        // Subcategory list — the mock batch classifies to 成语辨析.
        let subRow = app.staticTexts["成语辨析"]
        XCTAssertTrue(subRow.waitForExistence(timeout: 10), "subcategory list is blank — no rows appeared")
        subRow.tap()

        // Quiz screen: the first question header must appear.
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        // Answer all three questions, then finish (the last one shows 完成).
        let headers = ["第 1/", "第 2/", "第 3/"]
        for (index, expected) in headers.enumerated() {
            let currentHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '\(expected)'")).firstMatch
            XCTAssertTrue(currentHeader.waitForExistence(timeout: 10), "\(expected) header missing")
            // Option rows render their content in a WKWebView, so the button's
            // accessible label is just the keycap letter ("A").
            let firstOption = app.buttons["A"]
            XCTAssertTrue(firstOption.waitForExistence(timeout: 5), "option row missing")
            firstOption.tap()
            let button = app.buttons[index == headers.count - 1 ? "完成" : "下一题"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "answer did not reveal the next button")
            button.tap()
        }

        // Summary card.
        let summary = app.staticTexts["练习完成"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "summary card never appeared")
        app.buttons["返回题型列表"].tap()

        // The session end fired the best-effort attempt end (submitExam →
        // exam_ending, which the practice mock answers with JSON success).
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak server] _, _ in
                server?.calls.contains { $0.path.hasPrefix("/exam/exam_ending") } ?? false
            },
            object: nil
        )
        let waitResult = XCTWaiter().wait(for: [ended], timeout: 10)
        XCTAssertEqual(waitResult, .completed, "best-effort attempt end never reached /exam/exam_ending")
    }

    /// Local re-runs may restore a Keychain session (mock cookies persist per
    /// simulator); CI simulators are fresh, so the login page always shows
    /// there. Either way the app must reach the tab bar.
    private func logInIfNeeded(_ app: XCUIApplication) {
        guard app.buttons["password-login-entry"].waitForExistence(timeout: 5) else { return }
        // The user agreement is pre-checked by default — just enter the flow.
        app.buttons["password-login-entry"].tap()

        let phone = app.textFields["手机号"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "phone field missing")
        phone.tap()
        phone.typeText("13800138000")

        let password = app.secureTextFields["密码"]
        XCTAssertTrue(password.waitForExistence(timeout: 5), "password field missing")
        password.tap()
        password.typeText("hunter2")

        let submit = app.buttons["password-login-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "login button missing")
        submit.tap()
    }
}
