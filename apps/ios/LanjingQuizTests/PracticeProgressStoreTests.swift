import XCTest
@testable import LanjingQuiz

final class PracticeProgressStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "PracticeProgressStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> FileManagerPracticeProgressStore {
        FileManagerPracticeProgressStore(url: dir.appending(path: "practice-progress.json"))
    }

    func testStoreLoadReturnsNilWhenAbsent() async {
        let loaded = await store().load()
        XCTAssertNil(loaded)
    }

    func testStoreSaveLoadRoundTrip() async throws {
        let store = store()
        let progress = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1", "q2"])]
        try await store.save(progress)
        let loaded = await store.load()
        XCTAssertEqual(loaded, progress)
    }

    func testStoreClearRemovesFile() async throws {
        let store = store()
        try await store.save(["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"])])
        try await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }
}
