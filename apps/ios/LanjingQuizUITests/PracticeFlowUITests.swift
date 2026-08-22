import XCTest

/// Exercises the practice flow end-to-end against an in-process mock
/// upstream (LANJING_BASE_URL launch env): login → 练习 → auto-crawl of the
/// whole 机考题库 → 分类 (counts from the local bank) → 题型 → 答题 → 完成,
/// plus the 5 issue regressions: wrong-option marking, 答题卡 jump, 题干高度,
/// mid-run persistence across relaunch and full-screen quiz page.
/// Hermetic: requires no local server.
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
        // every execution, not just the first one per simulator. -reset-bank
        // also clears the persisted practice session (AppState.start), so
        // every run starts at 第 1/.
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)

        // Practice tab → the first-use crawl runs automatically, then the
        // category list appears with per-category counts from the local bank.
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 10), "练习 tab missing")
        practiceTab.tap()

        // Both mock papers are 言语理解 with the same q1–q5 batch — the crawl
        // dedupes by _id, so the category holds exactly 5 questions (q1–q3
        // 成语辨析 + q4/q5 虚词辨析; the latter pair feeds the 题干高度 test).
        let categoryRow = app.staticTexts["言语理解"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 20), "category list never appeared (crawl failed?)")
        XCTAssertTrue(app.staticTexts["5 题"].waitForExistence(timeout: 5), "category count missing")
        categoryRow.tap()

        // Subcategory list groups the crawled questions by 题型细分.
        let subRow = app.staticTexts["成语辨析"]
        XCTAssertTrue(subRow.waitForExistence(timeout: 10), "subcategory list is blank — no rows appeared")
        subRow.tap()

        // Quiz screen: the first question header must appear.
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        // Answer all three 成语辨析 questions, then finish (the last one shows 完成).
        let headers = ["第 1/", "第 2/", "第 3/"]
        for (index, expected) in headers.enumerated() {
            let currentHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '\(expected)'")).firstMatch
            XCTAssertTrue(currentHeader.waitForExistence(timeout: 10), "\(expected) header missing")
            // Option rows render their content in a WKWebView, so the button's
            // accessible label is just the keycap letter ("A").
            let firstOption = optionButton(app, "A")
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
        // The status row was removed from 我的 > 题库 — the refresh is done
        // when the button re-enables after the crawl (it is disabled while
        // .downloading).
        let reEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: app.buttons["更新题库"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [reEnabled], timeout: 10), .completed,
                       "更新题库 did not re-enable after refresh")
    }

    /// 问题 2 (选错选项标红) + 问题 5 (答题卡) + 问题 4 (全屏) regression test.
    /// q1's answer is A, so tapping B must mark the row wrong via the
    /// "option-B-wrong" accessibility identifier; the answer card sheet then
    /// jumps to any question and back.
    func testPracticeWrongOptionMarkedAndAnswerCard() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)

        enterSubcategory("成语辨析", app: app)

        // 问题 4: the pushed quiz page hides the tab bar (full screen).
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "quiz screen is blank — no question header")
        let profileTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(waitForDisappearance(profileTab, timeout: 5),
                      "tab bar still visible on the quiz page (问题 4)")

        // 问题 2: tap the WRONG option (B; q1's answer is A) — the row must
        // be marked "option-B-wrong"; the unselected correct row gets no
        // verdict identifier.
        let wrongOption = optionButton(app, "B")
        XCTAssertTrue(wrongOption.waitForExistence(timeout: 5), "option row missing")
        wrongOption.tap()
        XCTAssertTrue(app.buttons["option-B-wrong"].waitForExistence(timeout: 5),
                      "wrongly-tapped option was not marked (问题 2)")
        XCTAssertFalse(app.buttons["option-A-wrong"].exists, "unselected correct row must not be marked")

        // 问题 5: the answer card overlay opens, all dots render, tapping a
        // dot jumps the header (and closes the card).
        let dots = openAnswerCard(app)
        for dot in ["1", "2", "3"] {
            XCTAssertTrue(dots.buttons[dot].waitForExistence(timeout: 5), "answer card dot \(dot) missing")
        }
        dots.buttons["3"].tap()

        let header3 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 3/'")).firstMatch
        XCTAssertTrue(header3.waitForExistence(timeout: 5), "jump to question 3 did not move the header")
        XCTAssertTrue(waitForDisappearance(dots, timeout: 5), "answer card did not dismiss")
        // 问题 4 stays fixed after a jump.
        XCTAssertTrue(waitForDisappearance(profileTab, timeout: 5), "tab bar reappeared after jump")

        let dots2 = openAnswerCard(app)
        dots2.buttons["2"].tap()
        let header2 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2/'")).firstMatch
        XCTAssertTrue(header2.waitForExistence(timeout: 5), "jump to question 2 did not move the header")
        XCTAssertTrue(waitForDisappearance(dots2, timeout: 5), "answer card did not dismiss")

        // Finish the run to leave a clean persisted state.
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "完成")
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")
    }

    /// 问题 1 regression: the 题干 web view must resize with the question, in
    /// BOTH directions. 虚词辨析 holds q4 (short 题干) then q5 (very long 题干):
    /// short → long must grow, and jumping back (答题卡) long → short must
    /// shrink — the old bug kept the previous question's height. The 答题卡
    /// nav-bar button stays on-screen even when the long 题干 fills the page,
    /// so no scrolling is needed.
    func testPracticeStemHeightTracksQuestion() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)

        enterSubcategory("虚词辨析", app: app)

        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        // The question 题干 is the FIRST web view in the tree (headerRow is
        // plain text; option rows follow). Web-view frames are not
        // KVC-compliant, so poll instead of NSPredicate expectations.
        // With the paged TabView the (boundBy:) order no longer equals the
        // page order — take the stem that is actually on-screen.
        let questionWebView = try XCTUnwrap(visibleStemWebView(app))
        XCTAssertTrue(waitForElement(questionWebView, shorterThan: 200, timeout: 10),
                      "short question 题干 did not render short")

        // Short → long: answering q4 and advancing to the long q5 must grow
        // the 题干 (a stale height would keep it small — 问题 1).
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        let header2 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2/'")).firstMatch
        XCTAssertTrue(header2.waitForExistence(timeout: 10), "question 2 header missing")
        XCTAssertTrue(waitForElement(questionWebView, tallerThan: 400, timeout: 10),
                      "long question 题干 did not render tall (问题 1)")
        let longHeight = questionWebView.frame.height

        // Long → short (the user's exact complaint): jump back to q4 via the
        // answer card — the short 题干 must shrink, not keep the long height.
        let dots = openAnswerCard(app)
        dots.buttons["1"].tap()
        let header1 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header1.waitForExistence(timeout: 5), "jump back to question 1 did not move the header")
        XCTAssertTrue(waitForDisappearance(dots, timeout: 5), "answer card did not dismiss")
        XCTAssertTrue(waitForElement(questionWebView, shorterThan: 200, timeout: 10),
                      "short question kept the previous long height (问题 1)")
        XCTAssertLessThan(questionWebView.frame.height, longHeight * 0.6,
                          "short question 题干 did not shrink relative to the long one")
    }

    /// 问题 3 regression: a mid-run session survives app termination and
    /// relaunch (no -reset-bank on the second launch), resuming at the same
    /// question with the one-off "已恢复上次练习进度" banner.
    func testPracticeSessionResumesAfterTerminate() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"

        // Launch 1: crawl a fresh bank, answer q1, advance to question 2,
        // then kill the app — the mid-run session must survive on disk.
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)
        enterSubcategory("成语辨析", app: app)
        let header1 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header1.waitForExistence(timeout: 10), "quiz screen is blank — no question header")
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        let header2 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2/'")).firstMatch
        XCTAssertTrue(header2.waitForExistence(timeout: 5), "did not advance to question 2")
        app.terminate()

        // Launch 2 WITHOUT -reset-bank: the local bank and the persisted
        // session survive, so re-entering the same subcategory resumes at
        // question 2 (the Keychain login persists across launches; if the
        // simulator lost it, logInIfNeeded re-logs-in).
        app.launchArguments = []
        app.launch()
        logInIfNeeded(app)

        enterSubcategory("成语辨析", app: app)
        let resumedHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2/'")).firstMatch
        XCTAssertTrue(resumedHeader.waitForExistence(timeout: 10),
                      "session did not resume at question 2 (问题 3)")
        // The resumed session is live: 答题卡 button present (not finished).
        XCTAssertTrue(app.buttons["答题卡"].waitForExistence(timeout: 5), "答题卡 button missing after resume")

        // The one-off resume banner appears; 知道了 dismisses it.
        let banner = app.staticTexts["已恢复上次练习进度"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "resume banner missing")
        let gotIt = app.buttons["知道了"]
        XCTAssertTrue(gotIt.waitForExistence(timeout: 5), "banner dismiss button missing")
        gotIt.tap()
        XCTAssertTrue(waitForDisappearance(banner, timeout: 5), "banner did not dismiss")

        // Complete the resumed run.
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "完成")
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")
    }

    /// 需求 2:练习页像考试一样左右滑动切换题目,滑动位置(索引)已持久化。
    func testPracticeSwipeNavigatesQuestions() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)
        enterSubcategory("成语辨析", app: app)

        let header1 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header1.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        // 左滑 → 第 2 题。
        app.swipeLeft()
        let header2 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2/'")).firstMatch
        XCTAssertTrue(header2.waitForExistence(timeout: 5), "swipe left did not advance to question 2")

        // 右滑 → 回到第 1 题。
        app.swipeRight()
        XCTAssertTrue(header1.waitForExistence(timeout: 5), "swipe right did not return to question 1")

        // 答完收尾,不留脏状态。滑回第 1 题后从 q1 依次作答——成语辨析
        // 共 3 题,最后一题才显示"完成"。
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "完成")
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")
    }

    /// 需求 4:做完练习后,题型入口显示做题进度 x/xx(子类行精确值、
    /// 大类行聚合值)。
    func testPracticeEntryRowsShowProgressAfterRun() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)
        enterSubcategory("成语辨析", app: app)

        // 答完全部 3 题。
        let headers = ["第 1/", "第 2/", "第 3/"]
        for (index, expected) in headers.enumerated() {
            let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '\(expected)'")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 10), "\(expected) header missing")
            answerCurrentQuestion(app, letter: "A", advance: index == headers.count - 1 ? "完成" : "下一题")
        }
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")

        // 返回题型列表:子类行显示 3/3。
        app.buttons["返回题型列表"].tap()
        let subRowProgress = app.staticTexts["3/3"]
        XCTAssertTrue(subRowProgress.waitForExistence(timeout: 10), "subcategory row did not show 3/3 progress")

        // 大类行显示聚合进度 3/5(成语辨析 3 题已做 + 虚词辨析 0 题)。
        let subListBar = app.navigationBars["言语理解"]
        XCTAssertTrue(subListBar.waitForExistence(timeout: 5), "subcategory list never reappeared")
        tapBackButton(in: subListBar)
        let categoryProgress = app.staticTexts["3/5"]
        XCTAssertTrue(categoryProgress.waitForExistence(timeout: 5), "category row did not show 3/5 progress")
    }

    // MARK: - Helpers

    /// 练习 tab → category row → subcategory row (each level waits for its
    /// content to exist — same wait pattern as the main flow test).
    private func enterSubcategory(_ name: String, app: XCUIApplication, category: String = "言语理解") {
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 10), "练习 tab missing")
        practiceTab.tap()

        let categoryRow = app.staticTexts[category]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 20), "category list never appeared (crawl failed?)")
        waitForHittable(categoryRow)
        categoryRow.tap()

        let subRow = app.staticTexts[name]
        XCTAssertTrue(subRow.waitForExistence(timeout: 10), "subcategory list is blank — no rows appeared")
        waitForHittable(subRow)
        subRow.tap()
    }

    /// List 行刚出现时 frame 可能还没解析(冷启动首测常见):直接 tap 会算出
    /// hit point {-1,-1} 而静默失败——轮询到可点再返回,失败时给出明确断言。
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(element.isHittable, "element never became hittable: \(element.debugDescription)")
    }

    /// 页面上可见的选项按钮:TabView 分页让邻页同时存在于 a11y 树,裸
    /// firstMatch 可能命中屏幕外元素(not hittable)。分页切换动画期间相邻
    /// 两页可能同时(或都不)可点——轮询到"恰好 1 个可点"才返回,这是
    /// 当前页且动画已结束的确定性判据。
    private func optionButton(_ app: XCUIApplication, _ letter: String) -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let hittable = app.buttons.matching(identifier: letter).allElementsBoundByIndex.filter(\.isHittable)
            if hittable.count == 1 { return hittable[0] }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let matches = app.buttons.matching(identifier: letter).allElementsBoundByIndex
        return matches.first(where: \.isHittable) ?? matches.first!
    }

    /// 屏幕上可见的题干 web view(分页后元素(boundBy:) 顺序不再等于页码)。
    private func visibleStemWebView(_ app: XCUIApplication) -> XCUIElement? {
        let screen = app.windows.firstMatch.frame
        return app.webViews.allElementsBoundByIndex.first { view in
            let frame = view.frame
            return frame.minX >= 0 && frame.maxX <= screen.width && frame.maxY > 0
        }
    }

    /// Tap an option letter, then the reveal button ("下一题" / "完成").
    private func answerCurrentQuestion(_ app: XCUIApplication, letter: String, advance: String) {
        let option = optionButton(app, letter)
        XCTAssertTrue(option.waitForExistence(timeout: 5), "option row missing")
        option.tap()
        let button = app.buttons[advance]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "answer did not reveal the \(advance) button")
        button.tap()
    }

    /// Bounded polling for XCUIElement geometry: frame is a C struct (not
    /// KVC-compliant), so NSPredicate expectations cannot wait on it.
    private func waitForElement(_ element: XCUIElement, tallerThan height: CGFloat, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.frame.height > height { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return element.exists && element.frame.height > height
    }

    private func waitForElement(_ element: XCUIElement, shorterThan height: CGFloat, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.frame.height < height { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return element.exists && element.frame.height < height
    }

    /// Bounded polling until an element leaves the hierarchy (tab-bar hiding,
    /// sheet dismissal, banner dismissal).
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }

    /// Opens the answer-card overlay and returns its dot grid (the ScrollView
    /// carrying the "1".."n" buttons). The card is an overlay, not a sheet —
    /// sheet + hidden tab bar is an iOS 17 bug. On failure the accessibility
    /// tree is dumped so the CI log shows whether the overlay failed to
    /// render or the query itself was wrong.
    private func openAnswerCard(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["答题卡"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "答题卡 button missing")
        button.tap()
        let dots = app.scrollViews["practice-answer-card-grid"]
        if !dots.waitForExistence(timeout: 5) {
            print("ANSWER CARD UI TREE:\n\(app.debugDescription)")
            XCTAssertTrue(dots.exists, "answer card grid never appeared")
        }
        return dots
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
