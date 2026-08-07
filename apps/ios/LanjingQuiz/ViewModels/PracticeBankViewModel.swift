import Foundation
import Observation

/// Drives the 练习 tab: bank availability (first-use download gate) and the
/// category → subcategory → quiz flow. Practice is only usable after the
/// download completes — while .downloading the view shows progress only.
@MainActor
@Observable
final class PracticeBankViewModel {

    enum Phase: Equatable {
        case idle // storage not yet checked
        case downloading(QuestionBankClient.Progress)
        case failed(String)
        case ready
    }

    private let appState: AppState
    private let client: QuestionBankClient
    private let storage: BankStorage

    var phase: Phase = .idle
    var meta: BankMeta?
    var subcategories: [(name: String, count: Int)] = []
    var isShuffleEnabled = false
    var session: PracticeSession?

    init(
        appState: AppState,
        client: QuestionBankClient? = nil,
        storage: BankStorage? = nil
    ) {
        self.appState = appState
        self.client = client ?? appState.bankClient
        self.storage = storage ?? appState.bankStorage
    }

    // MARK: - Bank availability

    /// Entry point from the practice tab's .task: check the local bank and
    /// download on first use. Downloading blocks all practice UI.
    func ensureBankReady() async {
        guard phase == .idle else { return }
        if storage.isPopulated(), let meta = storage.loadMeta() {
            self.meta = meta
            phase = .ready
            return
        }
        await downloadIfNeeded(force: false)
    }

    /// 我的 > 更新题库: force a re-download; the old bank stays untouched
    /// until saveAll commits (meta written last).
    func updateBank() async {
        await downloadIfNeeded(force: true)
    }

    private func downloadIfNeeded(force: Bool) async {
        guard force || phase != .ready else { return }
        guard let baseURL = BankSettings.baseURL(from: BankSettings.loadServerURL()) else {
            phase = .failed("题库服务器地址无效（需 http:// 或 https://）")
            return
        }
        phase = .downloading(QuestionBankClient.Progress(fileIndex: 0, fileCount: 6, fileName: "meta.json"))
        do {
            let result = try await client.downloadBank(from: baseURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.phase { self?.phase = .downloading(progress) }
                }
            }
            try storage.saveAll(files: result.files, meta: result.meta)
            meta = result.meta
            phase = .ready
        } catch is CancellationError {
            // Tab switched away mid-download: partial files have no meta, so
            // the next entry re-downloads cleanly.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Navigation

    /// Loads and groups one category's questions (called from the subcategory
    /// list's .task; navigation itself is driven by NavigationStack links).
    func openCategory(_ category: String) async {
        guard let text = storage.loadCategoryText(category) else {
            phase = .failed("本地题库缺少 \(category).jsonl，请在 我的 > 更新题库 重新下载")
            return
        }
        let questions: [BankQuestion] = await Task.detached(priority: .userInitiated) {
            BankLogic.parseJSONL(text)
        }.value
        let groups = BankLogic.groupBySubcategory(questions)
        subcategories = groups.map { (name: $0.name, count: $0.questions.count) }
    }

    func startSession(category: String, subCategory: String) {
        guard let text = storage.loadCategoryText(category) else {
            phase = .failed("本地题库缺少 \(category).jsonl，请在 我的 > 更新题库 重新下载")
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
