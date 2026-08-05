import XCTest
@testable import LanjingQuiz

/// Same hardcoded interop vectors as apps/web/test/cookiecloud.test.js,
/// generated with the official extension's crypto-js implementation and
/// cross-checked against openssl. The two clients must agree byte-for-byte
/// with the browser extension; each platform keeps its own fixture copy.
final class CookieCloudCryptoTests: XCTestCase {

    // MARK: - Interop vectors (from crypto-js reference implementation)

    func testDeriveKeyMatchesExtensionDerivation() {
        XCTAssertEqual(CookieCloudCrypto.deriveKey(uuid: "test-uuid-1234", password: "test-password-5678"),
                       "ff67775c3432c7dc")
        XCTAssertEqual(CookieCloudCrypto.deriveKey(uuid: "uuid-b-998877", password: "pass-cc-xyz"),
                       "c6b0b54daf5c0c37")
    }

    func testDecryptsLegacyVectorsFromTheExtension() throws {
        // salt 0102030405060708, AES-256-CBC, EVP_BytesToKey(MD5)
        let legacy1 = "U2FsdGVkX18BAgMEBQYHCH6Zia7WX/lPiAk9Dhed3vx8TFLyPzqhwlaByt4349lTUfMD9vFVxkq9uyczthmIHA=="
        XCTAssertEqual(
            try CookieCloudCrypto.decrypt(legacy1, uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "legacy"),
            "{\"cookie_data\":{},\"local_storage_data\":{}}"
        )
        // salt a1b2c3d4e5f60718, realistic cookie payload
        let legacy2 = "U2FsdGVkX1+hssPU5fYHGKFCcwVDsFQ8Rtm6kcIhZQOLGfOj3mpiBUTubhhuM30y93XPXCTzCIoKFvZiSfs96BlaptjH00IiQ6xy4LqypQGZv8yFImuQ2fD+A2QsprFrSQOhfWQmiNCnDcuunWYEzzNeEPfXfCoJuq87hTQO9aU="
        XCTAssertEqual(
            try CookieCloudCrypto.decrypt(legacy2, uuid: "uuid-b-998877", password: "pass-cc-xyz", cryptoType: "legacy"),
            "{\"cookie_data\":{\"test.lanjingweike.com\":[{\"name\":\"sessionId\",\"value\":\"SESS_XYZ_123\"}]},\"local_storage_data\":{}}"
        )
    }

    func testDecryptsAndEncryptsFixedVectorsFromTheExtension() throws {
        // AES-128-CBC, key = UTF-8 bytes of the derived key, zero IV
        let fixed1 = "VJYTd1/GVaq27p6vmgE9FJdIPLMEnM7Bc9uRsLjAIjbtPU3Q6fFJAJZ1FSHe3FiV"
        let plain1 = "{\"cookie_data\":{},\"local_storage_data\":{}}"
        XCTAssertEqual(
            try CookieCloudCrypto.decrypt(fixed1, uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "aes-128-cbc-fixed"),
            plain1
        )
        XCTAssertEqual(
            try CookieCloudCrypto.encrypt(plain1, uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "aes-128-cbc-fixed"),
            fixed1
        )
        let fixed2 = "uc0DwkYemk+s/7Ru6tGsJ9n0WuKzQ+0ORnCGd2bKGp07Vp4sbbsX2COq5eO+64oQcFmYAN4k+LVd2C4meAHQ71ipaZwhbqjb1W+0/FhTmMmM++07mflHMHKuoQtx8TTT/HeQvR/TXH2kk2J27IDrRQ=="
        let plain2 = "{\"cookie_data\":{\"test.lanjingweike.com\":[{\"name\":\"sessionId\",\"value\":\"SESS_XYZ_123\"}]},\"local_storage_data\":{}}"
        XCTAssertEqual(
            try CookieCloudCrypto.encrypt(plain2, uuid: "uuid-b-998877", password: "pass-cc-xyz", cryptoType: "aes-128-cbc-fixed"),
            fixed2
        )
    }

    func testRoundTripsBothAlgorithms() throws {
        let plain = "{\"cookie_data\":{\"test.lanjingweike.com\":[{\"name\":\"sessionId\",\"value\":\"S1\"}]},\"local_storage_data\":{}}"
        for cryptoType in ["legacy", "aes-128-cbc-fixed"] {
            let encrypted = try CookieCloudCrypto.encrypt(
                plain, uuid: "uuid-b-998877", password: "pass-cc-xyz", cryptoType: cryptoType
            )
            XCTAssertEqual(
                try CookieCloudCrypto.decrypt(encrypted, uuid: "uuid-b-998877", password: "pass-cc-xyz", cryptoType: cryptoType),
                plain
            )
        }
    }

    func testDecryptAnyFallsBackWhenDeclaredTypeIsWrong() throws {
        // Fixed-IV payload marked "legacy" (observed in the wild), and the
        // reverse; unknown declared types try both algorithms.
        let fixed = "VJYTd1/GVaq27p6vmgE9FJdIPLMEnM7Bc9uRsLjAIjbtPU3Q6fFJAJZ1FSHe3FiV"
        let legacy = "U2FsdGVkX18BAgMEBQYHCH6Zia7WX/lPiAk9Dhed3vx8TFLyPzqhwlaByt4349lTUfMD9vFVxkq9uyczthmIHA=="
        let plain = "{\"cookie_data\":{},\"local_storage_data\":{}}"
        XCTAssertEqual(try CookieCloudCrypto.decryptAny(
            fixed, uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "legacy"
        ), plain)
        XCTAssertEqual(try CookieCloudCrypto.decryptAny(
            legacy, uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "aes-128-cbc-fixed"
        ), plain)
        XCTAssertEqual(try CookieCloudCrypto.decryptAny(
            fixed, uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "future-type"
        ), plain)
        XCTAssertThrowsError(try CookieCloudCrypto.decryptAny(
            fixed, uuid: "test-uuid-1234", password: "wrong-password", cryptoType: "legacy"
        ))
    }

    func testDecryptFailsClosedInsteadOfReturningGarbage() {
        let legacy = "U2FsdGVkX18BAgMEBQYHCH6Zia7WX/lPiAk9Dhed3vx8TFLyPzqhwlaByt4349lTUfMD9vFVxkq9uyczthmIHA=="
        // Wrong password -> PKCS7 padding failure.
        XCTAssertThrowsError(try CookieCloudCrypto.decrypt(
            legacy, uuid: "test-uuid-1234", password: "wrong-password", cryptoType: "legacy"
        ))
        // Legacy payload without the Salted__ header is rejected.
        XCTAssertThrowsError(try CookieCloudCrypto.decrypt(
            Data(repeating: 0x41, count: 32).base64EncodedString(),
            uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "legacy"
        ))
        // Unknown crypto_type (future extension versions) is rejected.
        XCTAssertThrowsError(try CookieCloudCrypto.decrypt(
            "x", uuid: "test-uuid-1234", password: "test-password-5678", cryptoType: "future-crypto-type"
        ))
        // Missing crypto_type defaults to legacy.
        XCTAssertEqual(
            try? CookieCloudCrypto.decrypt(legacy, uuid: "test-uuid-1234", password: "test-password-5678"),
            "{\"cookie_data\":{},\"local_storage_data\":{}}"
        )
    }

    // MARK: - Cookie conversions (mirror lib/cookiecloud.js)

    private func makeCookie(name: String, value: String, domain: String) -> HTTPCookie? {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])
    }

    func testCookieDataGroupsCookiesByDomain() throws {
        let cookies = [
            try XCTUnwrap(makeCookie(name: "sessionId", value: "S1", domain: "test.lanjingweike.com")),
            try XCTUnwrap(makeCookie(name: "JSESSIONID", value: "js1", domain: ".lanjingweike.com")),
            try XCTUnwrap(makeCookie(name: "other", value: "o1", domain: "www.baidu.com")),
        ]
        let data = CookieCloudConversion.cookieData(from: cookies)
        XCTAssertEqual(data.keys.count, 3)
        let lanjing = try XCTUnwrap(data["test.lanjingweike.com"])
        XCTAssertEqual(lanjing.first?["name"] as? String, "sessionId")
        XCTAssertEqual(lanjing.first?["value"] as? String, "S1")
        XCTAssertEqual(lanjing.first?["secure"] as? Bool, false) // default cookie
    }

    func testCookiesFromCookieDataImportsOnlyLanjingweike() throws {
        let cookieData: [String: Any] = [
            "test.lanjingweike.com": [
                ["name": "sessionId", "value": "S1", "domain": "test.lanjingweike.com", "path": "/"],
                ["name": "k", "value": "a=b=c", "domain": "test.lanjingweike.com", "path": "/"],
            ],
            ".lanjingweike.com": [
                ["name": "other", "value": "O1", "domain": ".lanjingweike.com", "path": "/", "session": true],
            ],
            "www.baidu.com": [
                ["name": "BAIDUID", "value": "B1", "domain": "www.baidu.com", "path": "/"],
            ],
            "garbage": "not-an-array",
        ]
        let cookies = CookieCloudConversion.cookies(from: cookieData)
        XCTAssertEqual(cookies.count, 3)
        XCTAssertTrue(cookies.contains { $0.name == "sessionId" && $0.value == "S1" })
        XCTAssertTrue(cookies.contains { $0.name == "k" && $0.value == "a=b=c" })
        XCTAssertTrue(cookies.contains { $0.name == "other" })
        XCTAssertFalse(cookies.contains { $0.name == "BAIDUID" })
        // entries missing name/value are skipped
        let sparse: [String: Any] = [
            "test.lanjingweike.com": [
                ["name": "", "value": "x", "domain": "test.lanjingweike.com", "path": "/"],
                ["name": "n", "domain": "test.lanjingweike.com", "path": "/"],
            ],
        ]
        XCTAssertEqual(CookieCloudConversion.cookies(from: sparse).count, 0)
    }

    func testCookiesFromCookieDataMapsExpiration() throws {
        let cookieData: [String: Any] = [
            "test.lanjingweike.com": [
                ["name": "persistent", "value": "P", "domain": "test.lanjingweike.com", "path": "/",
                 "expirationDate": 1_700_000_000],
            ],
        ]
        let cookies = CookieCloudConversion.cookies(from: cookieData)
        XCTAssertEqual(cookies.count, 1)
        let persistent = try XCTUnwrap(cookies.first)
        XCTAssertEqual(persistent.expiresDate?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    }

    func testMergeCookieDataKeepsNonLanjingweikeDomains() {
        let remote: [String: Any] = [
            "test.lanjingweike.com": [["name": "sessionId", "value": "OLD"]],
            "www.baidu.com": [["name": "BAIDUID", "value": "B1"]],
        ]
        let ours: [String: Any] = [
            "test.lanjingweike.com": [["name": "sessionId", "value": "NEW"]],
        ]
        let merged = CookieCloudConversion.mergeCookieData(remote: remote, ours: ours)
        XCTAssertEqual(merged.keys.count, 2)
        XCTAssertNotNil(merged["www.baidu.com"])
        let lanjing = merged["test.lanjingweike.com"] as? [[String: Any]]
        XCTAssertEqual(lanjing?.first?["value"] as? String, "NEW")
        // empty remote keeps only ours
        let onlyOurs = CookieCloudConversion.mergeCookieData(remote: [:], ours: ours)
        XCTAssertEqual(onlyOurs.keys.count, 1)
    }
}
