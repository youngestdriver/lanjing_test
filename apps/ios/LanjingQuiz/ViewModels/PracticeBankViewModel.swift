import Foundation
import Observation

/// Drives the 练习 tab: login gate, upstream paper list (机考题库), per-paper
/// question fetching with local classification, and the 分类 → 试卷 → 题型 →
/// quiz flow. Practice answers are graded locally and never submitted
/// upstream; the facade ends the created attempt when a session closes.
@MainActor
@Observable
final class PracticeBankViewModel {

    enum Phase: Equatable {
        case idle // not loaded yet
        case needsLogin
        case loading
        case failed(String)
        case ready
    }

    private let appState: AppState
    private let facade: PracticeUpstreamClient

    var phase: Phase = .idle
    var papersByCategory: [String: [Exam]] = [:]
    var subcategories: [(name: String, count: Int)] = []
    var isSubcategoryLoading = false
    var subcategoryError: String?
    var isShuffleEnabled = false
    var session: PracticeSession?

    /// Per-paper fetch cache — re-entering a subcategory of the same paper
    /// (or a stale back-stack session) refetches nothing.
    private var questionsByPaper: [Int: [BankQuestion]] = [:]

    init(appState: AppState, facade: PracticeUpstreamClient? = nil) {
        self.appState = appState
        self.facade = facade ?? PracticeUpstreamClient(api: appState.api)
    }

    // MARK: - Paper list

    /// Entry point from the practice tab's .task: load the 机考题库 paper list
    /// grouped by category. Requires an upstream session.
    func load() async {
        // Entry from .idle (first appearance) or .failed (retry button).
        if phase != .idle {
            guard case .failed = phase else { return }
        }
        guard appState.api.hasSession else {
            phase = .needsLogin
            return
        }
        phase = .loading
        do {
            let papers = try await facade.paperList()
            var grouped: [String: [Exam]] = [:]
            for paper in papers {
                guard let category = PracticeMapping.matchCategory(paper.name) else { continue }
                grouped[category, default: []].append(paper)
            }
            papersByCategory = grouped
            phase = .ready
        } catch {
            if !handleError(error) {
                phase = .failed(message(for: error))
            }
        }
    }

    func paperCount(for category: String) -> Int {
        papersByCategory[category]?.count ?? 0
    }

    func papers(for category: String) -> [Exam] {
        papersByCategory[category] ?? []
    }

    // MARK: - Subcategories

    /// Loads and groups one paper's questions into 题型细分 groups (called from
    /// the subcategory list's .task; the paper is entered on first fetch).
    func loadSubcategories(paper: Exam) async {
        isSubcategoryLoading = true
        subcategoryError = nil
        defer { isSubcategoryLoading = false }
        do {
            let questions = try await questions(for: paper)
            subcategories = BankLogic.groupBySubcategory(questions)
                .map { (name: $0.name, count: $0.questions.count) }
        } catch {
            if !handleError(error) {
                subcategoryError = message(for: error)
            }
        }
    }

    // MARK: - Quiz session

    func startSession(paper: Exam, subCategory: String) async {
        do {
            let questions = try await questions(for: paper).filter { $0.subCategory == subCategory }
            let ordered = isShuffleEnabled
                ? BankLogic.shuffled(questions, seed: UInt64.random(in: .min ... .max))
                : questions
            session = PracticeSession(
                paper: paper,
                category: PracticeMapping.matchCategory(paper.name) ?? "",
                subCategory: subCategory,
                questions: ordered
            )
        } catch {
            if !handleError(error) {
                phase = .failed(message(for: error))
            }
        }
    }

    /// Ends the session and best-effort-ends the attempt the app created for
    /// this paper (no-op for wfs=0 papers). Called on quiz exit.
    func endSession() {
        if let paper = session?.paper {
            facade.endAttempt(paper: paper)
        }
        session = nil
    }

    /// Called on quiz-view disappear (including the system back button):
    /// ends only a session that belongs to this quiz, so a stale session can
    /// never leak into a later entry of the same subcategory.
    func endSessionIfCurrent(paper: Exam, subCategory: String) {
        if session?.paper.id == paper.id && session?.subCategory == subCategory {
            endSession()
        }
    }

    // MARK: - Quiz

    var currentQuestion: BankQuestion? {
        guard let session, !session.isFinished else { return nil }
        return session.questions[session.index]
    }

    func tapOption(_ letter: String) {
        guard var session, !session.isFinished, session.revealed == nil,
              session.index < session.questions.count else { return }
        let question = session.questions[session.index]
        guard question.isGradable else {
            // Unknown answer: tapping reveals without grading.
            session.revealed = PracticeSession.RevealedAnswer(selected: [letter], correct: nil)
            self.session = session
            return
        }
        if question.isMulti {
            if session.selected.contains(letter) {
                session.selected.remove(letter)
            } else {
                session.selected.insert(letter)
            }
            self.session = session
        } else {
            let selected: Set<String> = [letter]
            let correct = BankLogic.grade(selected: selected, question: question)
            session.revealed = PracticeSession.RevealedAnswer(selected: selected, correct: correct)
            if correct == true { session.rightCount += 1 } else { session.wrongCount += 1 }
            self.session = session
        }
    }

    func confirmSelection() {
        guard var session, session.revealed == nil, !session.selected.isEmpty,
              session.index < session.questions.count else { return }
        let question = session.questions[session.index]
        let correct = BankLogic.grade(selected: session.selected, question: question)
        session.revealed = PracticeSession.RevealedAnswer(selected: session.selected, correct: correct)
        if correct == true { session.rightCount += 1 } else { session.wrongCount += 1 }
        self.session = session
    }

    func nextQuestion() {
        guard var session, session.revealed != nil else { return }
        session.index += 1
        session.selected = []
        session.revealed = nil
        self.session = session
    }

    // MARK: - Helpers

    private func questions(for paper: Exam) async throws -> [BankQuestion] {
        if let cached = questionsByPaper[paper.id] { return cached }
        let questions = try await facade.enterPaper(paper)
        questionsByPaper[paper.id] = questions
        return questions
    }

    /// Routes session-expiry/login errors through AppState (which redirects
    /// to the login screen); returns true when it did.
    private func handleError(_ error: Error) -> Bool {
        guard error is APIError else { return false }
        appState.handle(error)
        if appState.route == .login {
            phase = .needsLogin
            return true
        }
        return false
    }

    private func message(for error: Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }
}

/// One practice run. Value type mutated wholesale through the @Observable
/// property (Observation's modify accessor tracks it).
struct PracticeSession: Equatable {
    let paper: Exam
    let category: String
    let subCategory: String
    let questions: [BankQuestion]
    var index = 0
    var selected: Set<String> = [] // pending multi selection
    var revealed: RevealedAnswer? // nil = unanswered
    var rightCount = 0
    var wrongCount = 0

    struct RevealedAnswer: Equatable {
        let selected: Set<String>
        let correct: Bool? // nil = 无标准答案 (null-answer record)
    }

    var isFinished: Bool { index >= questions.count }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(index) / Double(questions.count)
    }
}
