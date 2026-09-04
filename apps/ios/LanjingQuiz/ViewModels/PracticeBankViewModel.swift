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
    private let progressStore: any PracticeProgressStoring
    /// 进度注册表内存副本(键 "\(category)/\(subCategory)")。
    private var progress: [String: PracticeProgress] = [:]

    /// The underlying store, exposed for the 我的 > 题库 > 日志导出 row.
    var bankStore: BankStorage { storage }

    var phase: Phase = .idle
    var meta: BankMeta?
    var subcategories: [(name: String, count: Int)] = []
    var session: PracticeSession?
    /// True when the current session was resumed from disk. Shown as a one-off
    /// banner by the quiz view; consumeResumeNotice() clears it (not persisted).
    private(set) var resumedFromDisk = false
    /// 首屏门控:preparing 时 PracticeQuizView 显示加载动画,当前题图片预取
    /// 就绪(或无图/超时)后进入 ready 才渲染答题页 —— 进入即完整,不再
    /// "空白页突然长出题干和选项"。
    enum EntryPhase: Equatable { case preparing, ready }
    private(set) var entryPhase: EntryPhase = .ready
    /// 后台顺延预取后续题图片;重新进入/退出会取消上一个任务。
    private var prefetchTask: Task<Void, Never>?

    init(appState: AppState, storage: BankStorage? = nil, facade: PracticeUpstreamClient? = nil,
         sessionStore: (any PracticeSessionStoring)? = nil,
         progressStore: (any PracticeProgressStoring)? = nil) {
        self.appState = appState
        self.storage = storage ?? appState.bankStorage
        self.facade = facade ?? PracticeUpstreamClient(api: appState.api)
        self.sessionStore = sessionStore ?? appState.practiceSessionStore
        self.progressStore = progressStore ?? appState.practiceProgressStore
    }

    // MARK: - Bank availability

    /// Reset after the local bank was deleted elsewhere (我的 > 删除题库):
    /// the next ensureBankReady re-crawls everything from scratch. The
    /// persisted practice session is cleared too (AppState.deleteBank also
    /// clears it — double insurance for the settings screen's own VM).
    /// 进度注册表同样清零:旧题 ID 无意义。
    func bankWasDeleted() {
        prefetchTask?.cancel()
        phase = .idle
        meta = nil
        subcategories = []
        session = nil
        resumedFromDisk = false
        entryPhase = .ready
        Task { try? await sessionStore.clear() }
        progress = [:]
        Task { try? await progressStore.clear() }
    }

    /// Entry point from the practice tab's .task: use the local bank when
    /// present, otherwise crawl the whole 机考题库 from upstream. The crawl
    /// blocks all practice UI while .downloading.
    func ensureBankReady() async {
        guard phase == .idle else { return }
        if storage.isPopulated(), let meta = storage.loadMeta() {
            self.meta = meta
            phase = .ready
            await loadProgressIfNeeded()
            return
        }
        await crawlIfNeeded(force: false)
    }

    /// 加载进度注册表(幂等,空表重载)。练习入口(题库列表/答题页)都会触发。
    private func loadProgressIfNeeded() async {
        guard progress.isEmpty else { return }
        if let loaded = await progressStore.load() { progress = loaded }
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
                // 题库内容可能已变化:按恢复规则(问题 ID 集合比对)旧存档
                // 不可能再匹配,清掉避免残留;失败(refresh 模式)不清,
                // 旧库保留,存档依然有效。进度注册表同样清空(旧 ID 无意义)。
                Task { try? await sessionStore.clear() }
                progress = [:]
                Task { try? await progressStore.clear() }
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
        await loadProgressIfNeeded()
        let questions = BankLogic.parseJSONL(text).filter { $0.subCategory == subCategory }
        let ordered = shuffleEnabled(category: category)
            ? BankLogic.shuffledKeepingGroups(questions, seed: UInt64.random(in: .min ... .max))
            : questions
        let saved = await sessionStore.load()
        let didResume: Bool
        if let resume = BankLogic.resumeCandidate(saved: saved, category: category, subCategory: subCategory,
                                                  ordered: ordered) {
            session = resume
            resumedFromDisk = true
            didResume = true
        } else {
            session = PracticeSession(category: category, subCategory: subCategory, questions: ordered)
            resumedFromDisk = false
            didResume = false
            persist()
        }
        if let session {
            await prepareEntry(for: session)
        }
        return didResume
    }

    // MARK: - 首屏门控 + 图片预取

    /// 门控:当前题图片预取就绪(单图超时 3s 兜底,无图题直接放行),随后
    /// 返回给视图 —— 期间 PracticeQuizView 显示加载动画。之后后台顺延预取
    /// 剩余题目,不阻塞翻页。
    private func prepareEntry(for session: PracticeSession) async {
        prefetchTask?.cancel()
        entryPhase = .preparing
        let urls = session.isFinished ? [] : imageURLs(in: session.questions[session.index])
        let deadline = Date(timeIntervalSinceNow: 3)
        for url in urls {
            guard Date() < deadline else { break }
            await fetchImage(url)
        }
        entryPhase = .ready
        startBackgroundPrefetch(for: session)
    }

    private func startBackgroundPrefetch(for session: PracticeSession) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self, !session.isFinished else { return }
            for index in (session.index + 1) ..< session.questions.count {
                if Task.isCancelled { return }
                for url in self.imageURLs(in: session.questions[index]) {
                    if Task.isCancelled { return }
                    await self.fetchImage(url)
                }
            }
        }
    }

    /// 题目全部图片 URL(stem/正文/选项),复用 RichHTMLContent 的解析规则。
    func imageURLs(in question: BankQuestion) -> [URL] {
        var urls: [URL] = []
        let htmls = [question.stem, question.question].compactMap { $0 } + question.options
        for html in htmls {
            for case .image(let url) in RichHTMLContent.segments(from: html) {
                if !urls.contains(url) { urls.append(url) }
            }
        }
        return urls
    }

    /// 预取单图到 PracticeImageStore;已有缓存或网络失败静默(动画兜底)。
    private func fetchImage(_ url: URL) async {
        guard PracticeImageStore.data(for: url) == nil else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
            PracticeImageStore.store(data, for: url)
        } catch is CancellationError {
            // 视图提前消失
        } catch {
            // 网络失败:保留原 src,量高动画兜底
        }
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
    /// (Plain system-back / swipe-back no longer clears anything: the ID-set
    /// resumeCandidate check is what prevents stale sessions from leaking.)
    func endSession() {
        prefetchTask?.cancel()
        session = nil
        resumedFromDisk = false
        entryPhase = .ready
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
            recordAnswered(question)
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
            recordAnswered(question)
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
        recordAnswered(question)
        session.answers[index] = answer
        self.session = session
        persist()
    }

    /// 已揭晓答案的题目记入进度注册表(跨会话累计,不因随机顺序/重新进入而
    /// 重复计算)。三种 reveal 路径共用:单选 tap、无答案 tap、多选 confirm。
    private func recordAnswered(_ question: BankQuestion) {
        let key = "\(question.category)/\(question.subCategory)"
        var entry = progress[key] ?? PracticeProgress()
        if !entry.answeredIDs.contains(question.id) {
            entry.answeredIDs.append(question.id)
            progress[key] = entry
            let snapshot = progress
            let store = progressStore
            Task { try? await store.save(snapshot) }
        }
    }

    // MARK: - 做题进度(需求 4)

    /// 某题型细分的已答数(跨会话累计)。
    func answeredCount(category: String, subCategory: String) -> Int {
        progress["\(category)/\(subCategory)"]?.answeredIDs.count ?? 0
    }

    /// 某大类下所有题型细分的已答数之和。
    func answeredCount(category: String) -> Int {
        progress.filter { $0.key.hasPrefix("\(category)/") }
            .values.reduce(0) { $0 + $1.answeredIDs.count }
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
