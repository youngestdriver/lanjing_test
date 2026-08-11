import XCTest
@testable import LanjingQuiz

final class PracticeSessionTests: XCTestCase {

    // MARK: - Fixtures

    private func makeQuestion(
        _ id: String,
        answer: BankQuestion.Answer? = BankQuestion.Answer(letters: ["A"])
    ) -> BankQuestion {
        BankQuestion(
            id: id,
            category: "言语理解",
            section: "逻辑填空",
            subCategory: "成语辨析",
            question: "<p>题干 \(id)</p>",
            stem: nil,
            options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"],
            answer: answer,
            analysis: nil,
            sourceExamName: "【言语理解（二）】机考题库",
            round: nil,
            collectedAt: nil
        )
    }

    /// 3-question mid-run session: q1 answered correctly, q2 answered wrong,
    /// q3 pending.
    private func makeSession() -> PracticeSession {
        var session = PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: [
            makeQuestion("q1"), makeQuestion("q2"), makeQuestion("q3")
        ])
        session.answers[0] = PracticeSession.PracticeAnswer(selected: ["A"], revealed: true, correct: true)
        session.answers[1] = PracticeSession.PracticeAnswer(selected: ["B"], revealed: true, correct: false)
        session.index = 1
        return session
    }

    // MARK: - Init

    func testInitAlignsAnswersWithQuestions() {
        let session = PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: [
            makeQuestion("q1"), makeQuestion("q2")
        ])
        XCTAssertEqual(session.answers.count, 2)
        XCTAssertTrue(session.answers.allSatisfy { !$0.revealed && $0.selected.isEmpty && $0.correct == nil })
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.progress, 0)
        XCTAssertFalse(session.isFinished)
    }

    // MARK: - Codable roundtrip (A.1)

    func testCodableRoundTrip() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PracticeSession.self, from: data)

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.index, 1)
        // Set<String> encodes as a JSON array and decodes losslessly.
        XCTAssertEqual(decoded.answers[0].selected, ["A"])
        XCTAssertEqual(decoded.answers[0].correct, true)
        XCTAssertEqual(decoded.answers[1].selected, ["B"])
        XCTAssertEqual(decoded.answers[1].correct, false)
        XCTAssertTrue(decoded.answers[2].selected.isEmpty)
        XCTAssertFalse(decoded.answers[2].revealed)
        XCTAssertNil(decoded.answers[2].correct)
        // Question HTML survives the roundtrip.
        XCTAssertEqual(decoded.questions.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(decoded.questions[0].question, "<p>题干 q1</p>")
    }

    /// Round-trip a revealed 无答案 answer (correct == nil after reveal must
    /// survive as nil — never a verdict — and the selected letters intact).
    func testCodableRoundTripUngradableAnswer() throws {
        var session = makeSession()
        session.answers[2] = PracticeSession.PracticeAnswer(selected: ["C"], revealed: true, correct: nil)
        let decoded = try JSONDecoder().decode(
            PracticeSession.self,
            from: try JSONEncoder().encode(session)
        )
        XCTAssertEqual(decoded, session)
        XCTAssertTrue(decoded.answers[2].revealed)
        XCTAssertNil(decoded.answers[2].correct)
        XCTAssertEqual(decoded.answers[2].selected, ["C"])
    }

    // MARK: - FileManagerPracticeSessionStore (A.2)

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "PracticeSessionStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> FileManagerPracticeSessionStore {
        FileManagerPracticeSessionStore(url: dir.appending(path: "practice-session.json"))
    }

    func testStoreLoadReturnsNilWhenAbsent() async {
        let store = store()
        XCTAssertNil(await store.load())
    }

    func testStoreSaveLoadRoundTrip() async throws {
        let store = store()
        let session = makeSession()
        try await store.save(session)
        let loaded = await store.load()
        XCTAssertEqual(loaded, session)
    }

    func testStoreClearRemovesFile() async throws {
        let store = store()
        try await store.save(makeSession())
        XCTAssertNotNil(await store.load())
        try await store.clear()
        XCTAssertNil(await store.load())
    }

    // MARK: - BankLogic.resumeCandidate (A.3)

    private var ordered: [BankQuestion] {
        [makeQuestion("q1"), makeQuestion("q2"), makeQuestion("q3")]
    }

    func testResumeCandidateMatchesUnfinishedSameOrder() {
        let saved = makeSession()
        XCTAssertEqual(
            BankLogic.resumeCandidate(saved: saved, category: "言语理解", subCategory: "成语辨析", ordered: ordered),
            saved
        )
    }

    func testResumeCandidateRejectsDifferentIdOrder() {
        let saved = makeSession()
        // Shuffle toggle / bank update change the order → fresh start.
        let shuffled = [makeQuestion("q2"), makeQuestion("q1"), makeQuestion("q3")]
        XCTAssertNil(BankLogic.resumeCandidate(saved: saved, category: "言语理解", subCategory: "成语辨析", ordered: shuffled))
    }

    func testResumeCandidateRejectsDifferentCategory() {
        let saved = makeSession()
        XCTAssertNil(BankLogic.resumeCandidate(saved: saved, category: "数字运算", subCategory: "成语辨析", ordered: ordered))
    }

    func testResumeCandidateRejectsDifferentSubCategory() {
        let saved = makeSession()
        XCTAssertNil(BankLogic.resumeCandidate(saved: saved, category: "言语理解", subCategory: "其他", ordered: ordered))
    }

    func testResumeCandidateRejectsFinished() {
        var saved = makeSession()
        saved.index = saved.questions.count
        XCTAssertNil(BankLogic.resumeCandidate(saved: saved, category: "言语理解", subCategory: "成语辨析", ordered: ordered))
    }

    func testResumeCandidateRejectsNilSaved() {
        XCTAssertNil(BankLogic.resumeCandidate(saved: nil, category: "言语理解", subCategory: "成语辨析", ordered: ordered))
    }

    // MARK: - Derived counts (A.4)

    func testCountsDerivedFromAnswers() {
        var session = makeSession()
        // q1 correct, q2 wrong, q3 answered but ungradable (correct == nil).
        session.answers[2] = PracticeSession.PracticeAnswer(selected: ["A"], revealed: true, correct: nil)
        XCTAssertEqual(session.rightCount, 1)
        XCTAssertEqual(session.wrongCount, 1)
        XCTAssertEqual(session.answeredCount, 3)

        // Pending answers do not count as answered; ungradable never counts
        // as wrong.
        session.answers[2] = PracticeSession.PracticeAnswer(selected: ["A"], revealed: false, correct: nil)
        XCTAssertEqual(session.rightCount, 1)
        XCTAssertEqual(session.wrongCount, 1)
        XCTAssertEqual(session.answeredCount, 2)
        XCTAssertEqual(session.progress, 1.0 / 3.0)

        // Multi-select correct = exactly the answer set.
        session.answers[1] = PracticeSession.PracticeAnswer(selected: ["A"], revealed: true, correct: true)
        XCTAssertEqual(session.rightCount, 2)
        XCTAssertEqual(session.wrongCount, 0)
    }
}
