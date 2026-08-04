import XCTest
@testable import LanjingQuiz

final class SessionExpiryTests: XCTestCase {

    func testLoginPageHTMLTriggersExpiry() {
        let loginHTML = """
        <!DOCTYPE html>
        <html><body><form action="/login/account/login"></form></body></html>
        """
        XCTAssertTrue(APIClient.detectSessionExpiry(status: 200, text: loginHTML, redirectTargets: []))
    }

    func testOnlineStatusZeroNumeric() {
        XCTAssertTrue(APIClient.detectSessionExpiry(status: 200, text: #"{"onlineStatus":0}"#, redirectTargets: []))
    }

    func testOnlineStatusZeroString() {
        XCTAssertTrue(APIClient.detectSessionExpiry(status: 200, text: #"{"onlineStatus":"0"}"#, redirectTargets: []))
    }

    func testOnlineStatusOneDoesNotTrigger() {
        XCTAssertFalse(APIClient.detectSessionExpiry(status: 200, text: #"{"onlineStatus":1}"#, redirectTargets: []))
    }

    func testNormalExamHTMLDoesNotTrigger() {
        XCTAssertFalse(APIClient.detectSessionExpiry(status: 200, text: Fixtures.examStartHTML, redirectTargets: []))
    }

    func testPlainJSONWithoutStatusDoesNotTrigger() {
        XCTAssertFalse(APIClient.detectSessionExpiry(status: 200, text: #"{"success":true}"#, redirectTargets: []))
    }

    func testRedirectToLoginTriggersExpiry() {
        let targets = [URL(string: "https://test.lanjingweike.com/login/account/login")!]
        XCTAssertTrue(APIClient.detectSessionExpiry(status: 302, text: "", redirectTargets: targets))
    }

    func testRedirectToOtherPathDoesNotTrigger() {
        let targets = [URL(string: "https://test.lanjingweike.com/exam")!]
        XCTAssertFalse(APIClient.detectSessionExpiry(status: 302, text: "", redirectTargets: targets))
    }

    func testOnlineStatusSubstringInNormalJSON() {
        // "onlineStatus" appearing with a different value must not match
        XCTAssertFalse(APIClient.detectSessionExpiry(status: 200, text: #"{"onlineStatus":10}"#, redirectTargets: []))
    }
}
