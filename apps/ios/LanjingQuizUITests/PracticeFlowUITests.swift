import XCTest

/// Exercises the practice flow end-to-end against the local bank server
/// (127.0.0.1:3000 — start `npm --prefix apps/web start` first). Skips when
/// the server is unreachable (CI has no bank server).
@MainActor
final class PracticeFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPracticeFlowLoadsQuestions() async throws {
        // Server liveness probe — CI has no bank server, so skip there.
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:3000/bank/meta.json")!)
        probe.timeoutInterval = 3
        var reachable = false
        if let (_, response) = try? await URLSession.shared.data(for: probe) {
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
        }
        try XCTSkipUnless(reachable, "bank server not reachable — start apps/web first")

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // Practice tab (the first-use download runs automatically).
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 5), "练习 tab missing")
        practiceTab.tap()

        // First-use download gate: wait for the category list (up to 60s).
        let categoryRow = app.staticTexts["言语理解"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 60), "category list never appeared (download failed?)")
        categoryRow.tap()

        // Subcategory list loads its data in .task — wait for a known one.
        let subRow = app.staticTexts["成语辨析"]
        XCTAssertTrue(subRow.waitForExistence(timeout: 10), "subcategory list is blank — no rows appeared")
        subRow.tap()

        // Quiz screen: the first question header must appear.
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        // Answer the question (tap the first option row) and expect the reveal.
        let firstOption = app.buttons.matching(NSPredicate(format: "label CONTAINS 'A.'")).firstMatch
        if firstOption.waitForExistence(timeout: 5) {
            firstOption.tap()
            let nextButton = app.buttons["下一题"]
            XCTAssertTrue(nextButton.waitForExistence(timeout: 5), "answer did not reveal 下一题")
        }
    }
}
