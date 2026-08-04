import XCTest
@testable import LanjingQuiz

final class HashingTests: XCTestCase {

    func testSHA256KnownVectors() {
        XCTAssertEqual(Hashing.sha256Hex("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.sha256Hex(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testMD5KnownVectors() {
        XCTAssertEqual(Hashing.md5Hex("abc"),
                       "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Hashing.md5Hex(""),
                       "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testOutputIsLowercaseHex() {
        let digest = Hashing.sha256Hex("Lanjing Quiz")
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest.lowercased(), digest)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })

        let md5 = Hashing.md5Hex("Lanjing Quiz")
        XCTAssertEqual(md5.count, 32)
        XCTAssertEqual(md5.lowercased(), md5)
    }
}
