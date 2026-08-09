import Foundation
import Observation

/// Drives the 练习 tab: the local question bank is crawled **directly from
/// the upstream platform** on first use (every 机考题库 paper, stored as
/// JSONL per category), then practice aggregates it by 一级分类 (大类) →
/// 二级分类 (题型细分) entirely offline. Answers are graded locally and
/// never submitted upstream.
@MainActor
@Observable
final class PracticeBankViewModel {

    enum Phase: Equatable {
        case idle // storage not yet checked
        case downloading(PracticeUpstreamClient.CrawlProgress)
        case needsLogin
        case failed(String)
        case ready
    }

    private let appState: AppState
    private let storage: BankStorage
    private let facade: PracticeUpstreamClient

    /// The underlying store, exposed for the 我的 > 题库 > 日志导出 row.
    var bankStore: BankStorage { storage }

    var phase: Phase = .idle
    var meta: BankMeta?
    var subcategories: [(name: String, count: Int)] = []
    var isShuffleEnabled = false
    var session: PracticeSession?

    init(appState: AppState, storage: BankStorage? = nil, facade: PracticeUpstreamClient? = nil) {
        self.appState = appState
        self.storage = storage ?? appState.bankStorage
        self.facade = facade ?? PracticeUpstreamClient(api: appState.api)
    }

    // MARK: - Bank availability

    /// Reset after the local bank was deleted elsewhere (我的 > 删除题库):
    /// the next ensureBankReady re-crawls everything from scratch.
    func bankWasDeleted() {
        phase = .idle
        meta = nil
        subcategories = []
        session = nil
    }

    /// Entry point from the practice tab's .task: use the local bank when
    /// present, otherwise crawl the whole 机考题库 from upstream. The crawl
    /// blocks all practice UI while .downloading.
    func ensureBankReady() async {
        guard phase == .idle else { return }
        if storage.isPopulated(), let meta = storage.loadMeta() {
            self.meta = meta
            phase = .ready
            return
        }
        await crawlIfNeeded(force: false)
    }

    /// 我的 > 更新题库: re-crawl EVERY paper and atomically replace the local
    /// bank (refresh mode — the old bank stays intact on failure).
    func updateBank() async {
        await crawlIfNeeded(force: true)
    }

    private func crawlIfNeeded(force: Bool) async {
        guard force || phase != .ready else { return }
        guard appState.api.hasSession else {
            phase = .needsLogin
            return
        }
        phase = .downloading(PracticeUpstreamClient.CrawlProgress(index: 0, total: 0, paperName: ""))
        do {
            try await facade.crawlAllPapers(storage: storage, refresh: force) { [weak self] progress in
                // The facade is @MainActor, so this callback is already on it.
                if case .downloading = self?.phase { self?.phase = .downloading(progress) }
            }
            meta = storage.loadMeta()
            phase = .ready
        } catch is CancellationError {
            // Tab switched away mid-crawl: per-paper meta.papers progress is
            // persisted, so the next entry resumes without re-entering papers.
        } catch {
            if !handleError(error) {
                phase = .failed(message(for: error))
            }
        }
    }

    // MARK: - Navigation

    /// Loads and groups one category's questions (called from the subcategory
    /// list's .task; navigation itself is driven by NavigationStack links).
    func openCategory(_ category: String) async {
        guard let text = storage.loadCategoryText(category) else {
            phase = .failed("本地题库缺少 \(category).jsonl，请在 我的 > 更新题库 重新爬取")
            return
        }
        let questions: [BankQuestion] = await Task.detached(priority: .userInitiated) {
            BankLogic.parseJSONL(text)
        }.value
        let groups = BankLogic.groupBySubcategory(questions)
        subcategories = groups.map { (name: $0.name, count: $0.questions.count) }
    }

    /// Local-only session start (no network): parse the category file, filter
    /// by 题型细分, optionally shuffle.
    func startSession(category: String, subCategory: String) {
        guard let text = storage.loadCategoryText(category) else {
            phase = .failed("本地题库缺少 \(category).jsonl，请在 我的 > 更新题库 重新爬取")
            return
        }
        let questions = BankLogic.parseJSONL(text).filter { $0.subCategory == subCategory }
        let ordered = isShuffleEnabled ? BankLogic.shuffled(questions, seed: UInt64.random(in: .min ... .max)) : questions
        session = PracticeSession(category: category, subCategory: subCategory, questions: ordered)
    }

    /// Clears the finished session (the quiz view dismisses itself via
    /// @Environment(\.dismiss) when popping back).
    func endSession() {
        session = nil
    }

    /// Called on quiz-view disappear (including the system back button):
    /// clears only a session that belongs to this quiz, so a stale session
    /// can never leak into a later entry of the same subcategory.
    func endSessionIfCurrent(category: String, subCategory: String) {
        if session?.category == category && session?.subCategory == subCategory {
            session = nil
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
