import XCTest
@testable import LanjingQuiz

/// Recording fake so VM-adjacent logic can run without touching the file system.
final class FakeBankStorage: BankStorage, @unchecked Sendable {
    private(set) var savedFiles: [(category: String, text: String)] = []
    private(set) var savedMeta: BankMeta?
    private(set) var savedAllCallCount = 0
    private(set) var removedCallCount = 0
    var populated = false
    var meta: BankMeta?
    var categoryTexts: [String: String] = [:]

    func isPopulated() -> Bool { populated }
    func loadMeta() -> BankMeta? { meta }
    func loadCategoryText(_ category: String) -> String? { categoryTexts[category] }
    func saveAll(files: [(category: String, text: String)], meta: BankMeta) throws {
        savedFiles = files
        savedMeta = meta
        savedAllCallCount += 1
    }
    func removeAll() throws { removedCallCount += 1 }
}

final class BankStorageTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "BankStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func storage() -> FileManagerBankStorage {
        FileManagerBankStorage(directory: dir)
    }

    private func meta(round: Int = 26) -> BankMeta {
        BankMeta(version: 1, round: round, lastRun: nil, targets: nil, counts: ["言语理解": 2])
    }

    private func files() -> [(category: String, text: String)] {
        BankLogic.categories.map { ($0, "{\"_id\":\"q1\"}\n") }
    }

    func testSaveAllThenLoadRoundTrip() throws {
        let store = storage()
        XCTAssertFalse(store.isPopulated())
        XCTAssertNil(store.loadMeta())

        try store.saveAll(files: files(), meta: meta())
        XCTAssertTrue(store.isPopulated())
        XCTAssertEqual(store.loadMeta()?.round, 26)
        // All 5 category files written by saveAll.
        for category in BankLogic.categories {
            XCTAssertEqual(store.loadCategoryText(category), "{\"_id\":\"q1\"}\n", category)
        }
        XCTAssertNil(store.loadCategoryText("未知分类"))
    }

    func testIsPopulatedFalseWhenMetaMissing() throws {
        let store = storage()
        // Write a category file but no meta — interrupted download state.
        let dirURL = dir!
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dirURL.appending(path: "言语理解.jsonl"))
        XCTAssertFalse(store.isPopulated())
    }

    func testRemoveAllDeletesEverything() throws {
        let store = storage()
        try store.saveAll(files: files(), meta: meta())
        XCTAssertTrue(store.isPopulated())
        try store.removeAll()
        XCTAssertFalse(store.isPopulated())
        XCTAssertNil(store.loadMeta())
    }

    func testFakeStorageRecordsCalls() throws {
        let fake = FakeBankStorage()
        fake.populated = true
        fake.meta = meta()
        fake.categoryTexts["言语理解"] = "line"
        XCTAssertTrue(fake.isPopulated())
        XCTAssertEqual(fake.loadMeta()?.round, 26)
        XCTAssertEqual(fake.loadCategoryText("言语理解"), "line")
        try fake.saveAll(files: files(), meta: meta())
        XCTAssertEqual(fake.savedAllCallCount, 1)
        XCTAssertEqual(fake.savedFiles.count, 5)
        XCTAssertEqual(fake.savedMeta?.round, 26)
        try fake.removeAll()
        XCTAssertEqual(fake.removedCallCount, 1)
    }
}
