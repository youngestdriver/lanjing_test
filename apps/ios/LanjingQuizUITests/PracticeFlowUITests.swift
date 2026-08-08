import XCTest

/// Exercises the practice flow end-to-end against an in-process mock
/// upstream (LANJING_BASE_URL launch env): login → 练习 → auto-crawl of the
/// whole 机考题库 → 分类 (counts from the local bank) → 题型 → 答题 → 完成,
/// then asserts the crawl best-effort-ended the fresh attempt exactly once.
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
        // Wipe the local bank so the crawl (and its attempt-end) runs on
        // every execution, not just the first one per simulator.
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)

        // Practice tab → the first-use crawl runs automatically, then the
        // category list appears with per-category counts from the local bank.
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 10), "练习 tab missing")
        practiceTab.tap()

        // Both mock papers are 言语理解 with the same q1–q3 batch — the crawl
        // dedupes by _id, so the category holds exactly 3 questions.
        let categoryRow = app.staticTexts["言语理解"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 20), "category list never appeared (crawl failed?)")
        XCTAssertTrue(app.staticTexts["3 题"].waitForExistence(timeout: 5), "category count missing")
        categoryRow.tap()

        // Subcategory list groups the crawled questions by 题型细分.
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

        // The crawl best-effort-ended exactly the wfs=1 paper's attempt
        // (paper 111 → exam_ending); the wfs=0 paper 222 was read-only.
        XCTAssertTrue(waitForCallCount(server, pathPrefix: "/exam/exam_ending", count: 1, timeout: 10),
                      "crawl did not end the fresh attempt exactly once")

        // 我的 > 更新题库 re-crawls EVERY paper and atomically replaces the
        // local bank (refresh mode): paper 111 gets a second attempt+end.
        // Pop back to the tab root first; each level waits for its nav bar to
        // settle so the back buttons exist (pop transitions differ per OS).
        app.buttons["返回题型列表"].tap()
        // The category list is the NavigationStack ROOT, so one back tap from
        // the subcategory list returns to the tab root.
        let subListBar = app.navigationBars["言语理解"] // the subcategory list's title is the category name
        XCTAssertTrue(subListBar.waitForExistence(timeout: 5), "subcategory list never reappeared")
        tapBackButton(in: subListBar)
        let profileTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5), "tab bar never reappeared")
        profileTab.tap()

        let updateButton = app.buttons["更新题库"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 10), "更新题库 button missing")
        updateButton.tap()

        XCTAssertTrue(waitForCallCount(server, pathPrefix: "/exam/exam_ending", count: 2, timeout: 10),
                      "更新题库 did not re-crawl the fresh paper")
        let refreshedStatus = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '已爬取'")).firstMatch
        XCTAssertTrue(refreshedStatus.waitForExistence(timeout: 10), "refresh status never shown")
    }

    /// Taps the nav bar's back button, waiting for it to exist first (pop
    /// transitions differ per OS and the button may lag the bar's title).
    private func tapBackButton(in navBar: XCUIElement) {
        let back = navBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "back button missing in \(navBar.identifier)")
        back.tap()
    }

    /// Waits until the mock has seen exactly `count` calls with the path prefix.
    private func waitForCallCount(_ server: MockUpstreamServer, pathPrefix: String, count: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak server] _, _ in
                server?.calls.filter { $0.path.hasPrefix(pathPrefix) }.count == count
            },
            object: nil
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            print("MOCK CALLS: \(server.calls.map { "\($0.method) \($0.path)" }.joined(separator: " | "))")
        }
        return result == .completed
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
