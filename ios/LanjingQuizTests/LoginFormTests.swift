import XCTest
@testable import LanjingQuiz

final class LoginFormTests: XCTestCase {

    func testLoginFormFields() {
        let phone = "13800000000"
        let password = "secret"
        let form = APIClient.loginForm(phone: phone, password: password)

        XCTAssertEqual(form["userName"], "13800000000@1")
        XCTAssertEqual(form["userNameInput"], phone)
        XCTAssertEqual(form["password"], Hashing.sha256Hex(password))
        XCTAssertEqual(form["passwordMD5"], Hashing.md5Hex(password))
        XCTAssertEqual(form["companyId"], "1")
        XCTAssertEqual(form["newCompanyId"], "1")
        XCTAssertEqual(form["remember"], "false")
        XCTAssertEqual(form["phoneAccount"], "")
        XCTAssertEqual(form["authCode"], "")
        XCTAssertEqual(form["captchaText"], "")
        XCTAssertEqual(form["nextUrl"], "")
    }

    func testFormEncode() {
        let encoded = APIClient.formEncode(["a": "1", "b": "hello world"])
        let parts = encoded.split(separator: "&").sorted()
        XCTAssertEqual(parts, ["a=1", "b=hello%20world"])
    }
}
