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
    private let sessionStore: any PracticeSessionStoring

    /// The underlying store, exposed for the 我的 > 题库 > 日志导出 row.
    var bankStore: BankStorage { storage }

    var phase: Phase = .idle
    var meta: BankMeta?
    var subcategories: [(name: String, count: Int)] = []
    var session: PracticeSession?
    /// True when the current session was resumed from disk. Shown as a one-off
    /// banner by the quiz view; consumeResumeNotice() clears it (not persisted).
    private(set) var resumedFromDisk = false

    init(appState: AppState, storage: BankStorage? = nil, facade: PracticeUpstreamClient? = nil,
         sessionStore: (any PracticeSessionStoring)? = nil) {
        self.appState = appState
        self.storage = storage ?? appState.bankStorage
        self.facade = facade ?? PracticeUpstreamClient(api: appState.api)
        self.sessionStore = sessionStore ?? appState.practiceSessionStore
    }

    // MARK: - Bank availability

    /// Reset after the local bank was deleted elsewhere (我的 > 删除题库):
    /// the next ensureBankReady re-crawls everything from scratch. The
    /// persisted practice session is cleared too (AppState.deleteBank also
    /// clears it — double insurance for the settings screen's own VM).
    func bankWasDeleted() {
        phase = .idle
        meta = nil
        subcategories = []
        session = nil
        resumedFromDisk = false
        Task { try? await sessionStore.clear() }
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
            if force {
                // 题库内容可能已变化:按恢复规则(问题 ID 顺序比对)旧存档
                // 不可能再匹配,清掉避免残留;失败(refresh 模式)不清,
                // 旧库保留,存档依然有效。
                Task { try? await sessionStore.clear() }
            }
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
    /// by 题型细分, optionally shuffle (comb stems stay grouped — see
    /// BankLogic.shuffledKeepingGroups). A persisted run resumes — and is NOT
    /// reshuffled (the archive already contains the shuffled order) — when
    /// BankLogic.resumeCandidate matches; otherwise a fresh session is created
    /// and persisted once. Returns whether a saved run was resumed.
    @discardableResult
    func resumeOrStart(category: String, subCategory: String) async -> Bool {
        guard let text = storage.loadCategoryText(category) else {
            phase = .failed("本地题库缺少 \(category).jsonl，请在 我的 > 更新题库 重新爬取")
            return false
        }
        let questions = BankLogic.parseJSONL(text).filter { $0.subCategory == subCategory }
        let ordered = shuffleEnabled(category: category)
            ? BankLogic.shuffledKeepingGroups(questions, seed: UInt64.random(in: .min ... .max))
            : questions
        let saved = await sessionStore.load()
        if let resume = BankLogic.resumeCandidate(saved: saved, category: category, subCategory: subCategory,
                                                  ordered: ordered) {
            session = resume
            resumedFromDisk = true
            return true
        }
        session = PracticeSession(category: category, subCategory: subCategory, questions: ordered)
        resumedFromDisk = false
        persist()
        return false
    }

    // MARK: - Shuffle preference (per-category, persisted independently)

    /// Each 大类 (言语理解/数字运算/…) remembers its own 随机顺序 switch — the
    /// setting applies to every 题型细分 inside it, and toggling one category
    /// never affects another (UserDefaults key "practice.shuffle.<category>").
    func shuffleEnabled(category: String) -> Bool {
        UserDefaults.standard.object(forKey: Self.shuffleKey(category: category)) as? Bool ?? false
    }

    func setShuffleEnabled(_ enabled: Bool, category: String) {
        UserDefaults.standard.set(enabled, forKey: Self.shuffleKey(category: category))
    }

    private static func shuffleKey(category: String) -> String {
        "practice.shuffle.\(category)"
    }

    /// Explicit exit (summary screen's 返回题型列表): drops the in-memory
    /// session and the persisted file — a finished run must never resume.
    /// (Plain system-back / swipe-back no longer clears anything: the ID-order
    /// resumeCandidate check is what prevents stale sessions from leaking.)
    func endSession() {
        session = nil
        resumedFromDisk = false
        Task { try? await sessionStore.clear() }
    }

    /// Dismisses the "已恢复上次练习进度" banner. Not persisted — the flag is
    /// reset on every resumeOrStart.
    func consumeResumeNotice() {
        resumedFromDisk = false
    }

    // MARK: - Persistence

    /// Snapshot-and-save the current session. The snapshot is captured at
    /// call time (value copy); the actor serializes writes so rapid mutations
    /// land in order (last write wins); failures are silent — the next
    /// mutation rewrites the file.
    private func persist() {
        guard let session else { return }
        let snapshot = session
        let store = sessionStore
        Task { try? await store.save(snapshot) }
    }

    // MARK: - Quiz

    var currentQuestion: BankQuestion? {
        guard let session, !session.isFinished else { return nil }
        return session.questions[session.index]
    }

    func tapOption(_ letter: String) {
        guard var session, !session.isFinished, session.index < session.questions.count else { return }
        let index = session.index
        let question = session.questions[index]
        var answer = session.answers[index]
        if !question.isGradable {
            // Unknown answer: tapping reveals without grading.
            answer.selected = [letter]
            answer.revealed = true
            answer.correct = nil
        } else if question.isMulti {
            if answer.selected.contains(letter) {
                answer.selected.remove(letter)
            } else {
                answer.selected.insert(letter)
            }
        } else {
            // Single-select grades and reveals immediately. The selected
            // letter is written back into answers — the data-layer fix for
            // "选错的选项没有标红" (the option row reads it from here).
            answer.selected = [letter]
            answer.revealed = true
            answer.correct = BankLogic.grade(selected: answer.selected, question: question)
        }
        session.answers[index] = answer
        self.session = session
        persist()
    }

    func confirmSelection() {
        guard var session, session.index < session.questions.count else { return }
        let index = session.index
        var answer = session.answers[index]
        guard !answer.revealed, !answer.selected.isEmpty else { return }
        let question = session.questions[index]
        answer.correct = BankLogic.grade(selected: answer.selected, question: question)
        answer.revealed = true
        session.answers[index] = answer
        self.session = session
        persist()
    }

    func nextQuestion() {
        guard var session, session.index < session.questions.count else { return }
        session.index += 1
        self.session = session
        if session.isFinished {
            // Run complete: clear the persisted file (a finished run must
            // not resume), but keep the in-memory session for the summary.
            Task { try? await sessionStore.clear() }
        } else {
            persist()
        }
    }

    /// 答题卡 jump: move the cursor to any question (answered or not) — the
    /// target's per-question state restores from `answers`. No-op for the
    /// current question or out-of-range indexes. Index is part of the
    /// persisted state, so a jump survives exit/relaunch.
    func jumpTo(_ index: Int) {
        guard var session, index != session.index,
              (0 ..< session.questions.count).contains(index) else { return }
        session.index = index
        self.session = session
        persist()
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
/// property (Observation's modify accessor tracks it). Per-question state
/// lives in `answers` (index-aligned with `questions`), so the 答题卡 can jump
/// to any question without losing pending/revealed state. Codable + Sendable
/// let the whole run be persisted off the main actor (strict concurrency).
struct PracticeSession: Codable, Equatable, Sendable {
    let category: String
    let subCategory: String
    let questions: [BankQuestion]           // BankQuestion 已 Codable+Sendable
    var index = 0
    var answers: [PracticeAnswer]

    /// One question's state: pending multi-select lives in `selected` with
    /// `revealed == false`; after reveal `correct` is the verdict, and
    /// `correct == nil` after reveal means 无答案 (ungradable record).
    struct PracticeAnswer: Codable, Equatable, Sendable {
        var selected: Set<String> = []
        var revealed = false
        var correct: Bool?   // nil while pending; nil after reveal = 无答案
    }

    init(category: String, subCategory: String, questions: [BankQuestion]) {
        self.category = category
        self.subCategory = subCategory
        self.questions = questions
        self.answers = questions.map { _ in PracticeAnswer() }
    }

    var isFinished: Bool { index >= questions.count }

    var currentAnswer: PracticeAnswer? {
        guard index < answers.count else { return nil }
        return answers[index]
    }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(index) / Double(questions.count)
    }

    // 由 answers 推导,summary 与答题卡统计永不漂移。
    // 语义微调:无答案题(correct == nil)不再计为答错。
    var rightCount: Int { answers.reduce(0) { $0 + ($1.correct == true ? 1 : 0) } }
    var wrongCount: Int { answers.reduce(0) { $0 + ($1.correct == false ? 1 : 0) } }
    var answeredCount: Int { answers.reduce(0) { $0 + ($1.revealed ? 1 : 0) } }
}
