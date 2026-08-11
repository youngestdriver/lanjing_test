import XCTest
@testable import LanjingQuiz

/// In-memory practice-session store: records saves/clears, can be preloaded
/// ("seeded") with a resume candidate, never touches the file system.
actor FakePracticeSessionStore: PracticeSessionStoring {
    private(set) var stored: PracticeSession?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() async -> PracticeSession? { stored }
    func save(_ session: PracticeSession) async throws {
        stored = session
        saveCount += 1
    }
    func clear() async throws {
        stored = nil
        clearCount += 1
    }

    /// Deterministic barrier: persist() fire-and-forget Tasks make a bare
    /// count read racy, so tests wait until the actor has processed `target`
    /// saves. The actor runs enqueued jobs in order, and these Tasks are
    /// created on the main actor before the test suspends here — this loop
    /// terminates.
    func awaitSaveCount(_ target: Int) async {
        while saveCount < target { await Task.yield() }
    }

    func awaitClearCount(_ target: Int) async {
        while clearCount < target { await Task.yield() }
    }
}

@MainActor
final class PracticeBankViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeQuestion(_ id: String, answer: BankQuestion.Answer?) -> BankQuestion {
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

    /// 3-question 成语辨析 bank: q1 single-select with answer B, q2 无答案
    /// (answer nil), q3 multi-select with A+C. Encoded as JSONL like the
    /// on-disk category file.
    private func categoryTexts() -> [String: String] {
        let questions = [
            makeQuestion("q1", answer: BankQuestion.Answer(letters: ["B"])),
            makeQuestion("q2", answer: nil),
            makeQuestion("q3", answer: BankQuestion.Answer(letters: ["A", "C"])),
        ]
        let encoder = JSONEncoder()
        let lines = questions.map { String(data: try! encoder.encode($0), encoding: .utf8)! }
        return ["言语理解": lines.joined(separator: "\n") + "\n"]
    }

    private var orderedQuestions: [BankQuestion] {
        BankLogic.parseJSONL(categoryTexts()["言语理解"]!)
            .filter { $0.subCategory == "成语辨析" }
    }

    private func makeVM(storage: FakeBankStorage, sessionStore: FakePracticeSessionStore) -> PracticeBankViewModel {
        PracticeBankViewModel(appState: AppState(), storage: storage, sessionStore: sessionStore)
    }

    // MARK: - tapOption (问题 2 regression pins)

    /// Regression pin for 问题 2 (选错选项没有标红): the selected letter must be
    /// written back into answers so the option row can mark it wrong.
    func testTapOptionSingleWrongWritesSelected() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1's answer is B → wrong
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.answers[0].selected, ["A"])
        XCTAssertTrue(session.answers[0].revealed)
        XCTAssertEqual(session.answers[0].correct, false)
        XCTAssertEqual(session.rightCount, 0)
        XCTAssertEqual(session.wrongCount, 1)
        XCTAssertEqual(session.answeredCount, 1)
        // The mutation was persisted (fresh-start save + tap save).
        await store.awaitSaveCount(2)
        XCTAssertEqual(await store.stored?.answers[0].selected, ["A"])
        XCTAssertEqual(await store.stored?.index, 0)
    }

    func testTapOptionSingleCorrect() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("B") // q1's answer is B → correct
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.answers[0].correct, true)
        XCTAssertEqual(session.rightCount, 1)
        XCTAssertEqual(session.wrongCount, 0)
        await store.awaitSaveCount(2)
        XCTAssertEqual(await store.stored?.answers[0].correct, true)
    }

    func testTapOptionUngradableNoVerdict() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1 wrong (counts 1)
        vm.nextQuestion()
        vm.tapOption("A") // q2 has no known answer → reveal, no verdict
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 1)
        XCTAssertTrue(session.answers[1].revealed)
        XCTAssertNil(session.answers[1].correct)
        XCTAssertEqual(session.answers[1].selected, ["A"])
        // 无答案 is answered but never counts as right or wrong.
        XCTAssertEqual(session.answeredCount, 2)
        XCTAssertEqual(session.rightCount, 0)
        XCTAssertEqual(session.wrongCount, 1)
    }

    func testMultiToggleThenConfirm() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.nextQuestion() // q1 unanswered — advancing is allowed
        vm.nextQuestion() // → q3 (multi, A+C)
        XCTAssertNil(vm.session?.answers[2].correct)

        vm.tapOption("A")
        vm.tapOption("C")
        XCTAssertEqual(vm.session?.answers[2].selected, ["A", "C"])
        XCTAssertFalse(vm.session?.answers[2].revealed ?? true)

        vm.confirmSelection()
        let session = try XCTUnwrap(vm.session)
        XCTAssertTrue(session.answers[2].revealed)
        XCTAssertEqual(session.answers[2].correct, true)
        XCTAssertEqual(session.rightCount, 1)
        XCTAssertEqual(session.wrongCount, 0)
    }

    func testMultiWrongSelectionGradedWrong() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.nextQuestion()
        vm.nextQuestion() // → q3
        vm.tapOption("B") // only one of A+C → wrong
        vm.confirmSelection()
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.answers[2].correct, false)
        XCTAssertEqual(session.wrongCount, 1)
    }

    // MARK: - nextQuestion / jumpTo

    func testNextQuestionKeepsAnswersAndClearsOnFinish() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1 wrong
        vm.nextQuestion()
        var session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 1)
        // Per-question state travels with answers, never cleared.
        XCTAssertEqual(session.answers[0].selected, ["A"])
        XCTAssertEqual(session.answers[0].correct, false)
        XCTAssertTrue(session.answers[0].revealed)

        // Walk to the end: q2 无答案, q3 multi A+C.
        vm.tapOption("A")
        vm.nextQuestion()
        vm.tapOption("A")
        vm.tapOption("C")
        vm.confirmSelection()
        vm.nextQuestion() // finish

        session = try XCTUnwrap(vm.session)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.rightCount, 1) // q3
        XCTAssertEqual(session.wrongCount, 1) // q1
        // Finished run: file cleared, in-memory session kept for the summary.
        await store.awaitClearCount(1)
        XCTAssertNil(await store.stored)
    }

    func testJumpToMovesIndexAndRestoresState() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1 answered wrong
        vm.nextQuestion() // index 1
        vm.jumpTo(0)      // back to the answered question
        var session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.answers[0].selected, ["A"])
        XCTAssertEqual(session.answers[0].correct, false)

        vm.jumpTo(2) // forward to the pending question
        session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 2)
        XCTAssertFalse(session.answers[2].revealed)
        XCTAssertTrue(session.answers[2].selected.isEmpty)

        // Same index / out of range are no-ops.
        vm.jumpTo(2)
        vm.jumpTo(99)
        vm.jumpTo(-1)
        XCTAssertEqual(vm.session?.index, 2)

        // Persisted: fresh-start save + tap + next + jump + jump = 5.
        await store.awaitSaveCount(5)
        XCTAssertEqual(await store.saveCount, 5)
        XCTAssertEqual(await store.stored?.index, 2)
    }

    // MARK: - resume / persist / clear

    func testResumeOrStartResumesMatching() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        // Seed a saved run: same subcategory, same ID order, mid-run.
        var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: orderedQuestions)
        saved.answers[0] = PracticeSession.PracticeAnswer(selected: ["A"], revealed: true, correct: false)
        saved.index = 1
        try await store.save(saved)

        let vm = makeVM(storage: storage, sessionStore: store)
        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(resumed)
        XCTAssertTrue(vm.resumedFromDisk)
        XCTAssertEqual(vm.session, saved)
        XCTAssertEqual(vm.session?.index, 1)
        XCTAssertEqual(vm.session?.wrongCount, 1)
        // A resumed run is not re-persisted (only the seed save happened).
        XCTAssertEqual(await store.saveCount, 1)
    }

    func testResumeOrStartFreshOnDifferentIdOrder() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let original = orderedQuestions
        // Different ID order (e.g. after a bank update or shuffle toggle).
        var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析",
                                    questions: [original[1], original[0], original[2]])
        saved.index = 1
        try await store.save(saved)

        let vm = makeVM(storage: storage, sessionStore: store)
        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertFalse(resumed)
        XCTAssertFalse(vm.resumedFromDisk)
        XCTAssertEqual(vm.session?.index, 0)
        XCTAssertEqual(vm.session?.questions.map(\.id), original.map(\.id))
        // Fresh run persisted once (on top of the seed save).
        await store.awaitSaveCount(2)
        XCTAssertEqual(await store.saveCount, 2)
    }

    func testResumeOrStartMissingCategoryFails() async {
        let storage = FakeBankStorage() // no category texts
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)

        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertFalse(resumed)
        XCTAssertNil(vm.session)
        guard case .failed = vm.phase else {
            return XCTFail("expected .failed phase, got \(vm.phase)")
        }
    }

    func testConsumeResumeNotice() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: orderedQuestions)
        saved.index = 2
        try await store.save(saved)

        let vm = makeVM(storage: storage, sessionStore: store)
        _ = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(vm.resumedFromDisk)

        vm.consumeResumeNotice()
        XCTAssertFalse(vm.resumedFromDisk)
    }

    func testEndSessionClearsPersistedRun() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertNotNil(vm.session)

        vm.endSession()
        XCTAssertNil(vm.session)
        XCTAssertFalse(vm.resumedFromDisk)
        await store.awaitClearCount(1)
        XCTAssertNil(await store.stored)
    }

    func testBankDeletedClearsSessionAndSave() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertNotNil(await store.stored)

        vm.bankWasDeleted()
        XCTAssertNil(vm.session)
        XCTAssertFalse(vm.resumedFromDisk)
        XCTAssertEqual(vm.phase, .idle)
        await store.awaitClearCount(1)
        XCTAssertNil(await store.stored)
    }
}
