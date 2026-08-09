import XCTest
@testable import LanjingQuiz

/// Recording fake so VM-adjacent logic can run without touching the file system.
final class FakeBankStorage: BankStorage, @unchecked Sendable {
    private(set) var savedFiles: [(category: String, text: String)] = []
    private(set) var savedMeta: BankMeta?
    private(set) var savedAllCallCount = 0
    private(set) var appendedRecords: [String: [BankQuestion]] = [:]
    private(set) var saveMetaCallCount = 0
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
    func appendRecords(_ records: [BankQuestion], for category: String) throws {
        appendedRecords[category, default: []].append(contentsOf: records)
    }
    func saveMeta(_ meta: BankMeta) throws {
        savedMeta = meta
        saveMetaCallCount += 1
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

    private func makeQuestion(_ id: String, category: String = "言语理解") -> BankQuestion {
        BankQuestion(
            id: id,
            category: category,
            section: "逻辑填空",
            subCategory: "成语辨析",
            question: "<p>题干</p>",
            stem: nil,
            options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"],
            answer: BankQuestion.Answer(letters: ["A"]),
            analysis: nil,
            sourceExamName: "【言语理解（二）】机考题库",
            round: nil,
            collectedAt: nil
        )
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
        // Write a category file but no meta — interrupted crawl state.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "言语理解.jsonl"))
        XCTAssertFalse(store.isPopulated())
    }

    func testAppendRecordsAccumulatesWithoutClobbering() throws {
        let store = storage()
        try store.appendRecords([makeQuestion("q1")], for: "言语理解")
        try store.appendRecords([makeQuestion("q2")], for: "言语理解")
        let text = try XCTUnwrap(store.loadCategoryText("言语理解"))
        XCTAssertEqual(BankLogic.parseJSONL(text).map(\.id), ["q1", "q2"])
        // Append to an absent category creates the file; other categories untouched.
        XCTAssertNil(store.loadCategoryText("数字运算"))
    }

    func testSaveMetaUpdatesMetaWithoutTouchingFiles() throws {
        let store = storage()
        try store.saveMeta(meta(round: 1))
        try store.appendRecords([makeQuestion("q1")], for: "言语理解")
        try store.saveMeta(meta(round: 2))
        XCTAssertEqual(store.loadMeta()?.round, 2)
        XCTAssertEqual(BankLogic.parseJSONL(store.loadCategoryText("言语理解") ?? "").map(\.id), ["q1"])
    }

    func testMetaRoundTripsPapersField() throws {
        let store = storage()
        let meta = BankMeta(
            version: 1,
            round: 3,
            lastRun: "2026-08-08T00:00:00Z",
            targets: BankLogic.categories,
            counts: ["言语理解": 2],
            papers: ["111": true]
        )
        try store.saveMeta(meta)
        XCTAssertEqual(store.loadMeta(), meta)
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
        try fake.appendRecords([makeQuestion("q1")], for: "言语理解")
        XCTAssertEqual(fake.appendedRecords["言语理解"]?.map(\.id), ["q1"])
        try fake.saveMeta(meta(round: 27))
        XCTAssertEqual(fake.saveMetaCallCount, 1)
        XCTAssertEqual(fake.savedMeta?.round, 27)
        try fake.removeAll()
        XCTAssertEqual(fake.removedCallCount, 1)
    }

    // MARK: - Crawl log

    private func logEntry(
        step: PracticeUpstreamClient.CrawlLogEntry.Step = .enter,
        outcome: PracticeUpstreamClient.CrawlLogEntry.Outcome = .success,
        paperName: String = "E1"
    ) -> PracticeUpstreamClient.CrawlLogEntry {
        PracticeUpstreamClient.CrawlLogEntry(
            timestamp: "2026-08-10T00:10:00Z",
            paperId: "E1",
            paperName: paperName,
            step: step,
            outcome: outcome,
            message: nil
        )
    }

    func testCrawlLogStartsEmpty() {
        XCTAssertEqual(storage().loadCrawlLog(), [])
    }

    func testAppendCrawlLogAccumulatesWithoutClobbering() throws {
        let store = storage()
        try store.appendCrawlLog([logEntry(outcome: .success)])
        try store.appendCrawlLog([logEntry(step: .save, outcome: .failure)])
        XCTAssertEqual(store.loadCrawlLog().map(\.step), [.enter, .save])
        XCTAssertEqual(store.loadCrawlLog().map(\.outcome), [.success, .failure])
        // empty batch is a no-op
        try store.appendCrawlLog([])
        XCTAssertEqual(store.loadCrawlLog().count, 2)
    }

    func testRemoveAllDeletesCrawlLog() throws {
        let store = storage()
        try store.appendCrawlLog([logEntry()])
        try store.removeAll()
        XCTAssertEqual(store.loadCrawlLog(), [])
    }
}
