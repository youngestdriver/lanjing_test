import Foundation

/// Pure mapping helpers for the practice flow — ports of the collector's
/// helpers in apps/bank/lib/question-bank.js (matchCategory / isTargetExam /
/// cleanSection / joinQuestions / buildRecord), wired to the Swift
/// QuestionClassifier. All static and Sendable, so unit tests drive them
/// without a client.
enum PracticeMapping: Sendable {

    /// First of the 5 机考 categories contained in the paper name wins
    /// (【言语理解（二）】机考题库 → 言语理解). nil for non-target papers.
    static func matchCategory(_ paperName: String) -> String? {
        for category in BankLogic.categories {
            if paperName.contains(category) { return category }
        }
        return nil
    }

    /// True for 机考题库-style papers whose name carries one of the target
    /// categories. Deliberately NOT filtered by wfs — wfs only selects the
    /// enter path and whether the attempt may be ended (see the facade).
    static func isTargetExam(_ exam: Exam) -> Bool {
        exam.style.contains("机考题库") && matchCategory(exam.name) != nil
    }

    static let defaultSection = "(无分类)"

    /// Trim a section title; empty becomes the "(无分类)" placeholder.
    private static func normalizeSection(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultSection : t
    }

    /// Section labels from the answer card carry a point-count suffix, e.g.
    /// "逻辑填空(共200题,每题1分,合计200.0分)" → "逻辑填空". Only the "(共…)" tail
    /// is stripped; informative notes like "（仅中国石油和国家管网考）" survive.
    static func cleanSection(_ title: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\(共[^)]*\\)\\s*$") else {
            return normalizeSection(title)
        }
        let range = NSRange(location: 0, length: (title as NSString).length)
        let cleaned = regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
        return normalizeSection(cleaned)
    }

    /// Join fetched question DTOs with their answer-card states. The server
    /// emits both in testIds order; match by questionsId first (first-wins on
    /// duplicates), falling back to positional join. Unmatched questions get
    /// the placeholder section. Returns (question, section) pairs.
    static func join(questions: [QuestionDTO], states: [QuestionState]) -> [(question: QuestionDTO, section: String)] {
        var stateById: [String: QuestionState] = [:]
        for state in states where !stateById.keys.contains(state.questionsId) {
            stateById[state.questionsId] = state
        }
        var joined: [(question: QuestionDTO, section: String)] = []
        for (index, question) in questions.enumerated() {
            let state = stateById[question._id] ?? (index < states.count ? states[index] : nil)
            joined.append((question: question, section: state?.section ?? defaultSection))
        }
        return joined
    }

    /// Map one upstream question DTO + its answer-card section into a
    /// BankQuestion (port of buildRecord + classifier wiring):
    ///   - all 4 option slots preserved (empty strings = 填空 slots);
    ///   - correct letters from the keyN flags (>1 多选, ==1 单选, else
    ///     test_ans_right when non-empty, else nil — honest "unknown");
    ///   - section cleaned, subCategory derived by the rule engine.
    static func bankQuestion(dto: QuestionDTO, section: String, category: String, paperName: String) -> BankQuestion {
        let correctKeys = [(dto.key1, "A"), (dto.key2, "B"), (dto.key3, "C"), (dto.key4, "D")]
            .compactMap { $0.0 == "1" ? $0.1 : nil }
        let answer: BankQuestion.Answer?
        if correctKeys.count > 1 {
            answer = BankQuestion.Answer(letters: correctKeys)
        } else if correctKeys.count == 1 {
            answer = BankQuestion.Answer(letters: [correctKeys[0]])
        } else if let fallback = dto.test_ans_right, !fallback.isEmpty {
            answer = BankQuestion.Answer(letters: [fallback])
        } else {
            answer = nil
        }
        let cleanedSection = cleanSection(section)
        return BankQuestion(
            id: dto._id,
            category: category,
            section: cleanedSection,
            subCategory: QuestionClassifier.classify(
                category: category,
                section: cleanedSection,
                question: dto.question,
                analysis: dto.analysis
            ),
            question: dto.question,
            options: [dto.answer1 ?? "", dto.answer2 ?? "", dto.answer3 ?? "", dto.answer4 ?? ""],
            answer: answer,
            analysis: dto.analysis,
            sourceExamName: paperName,
            round: nil,
            collectedAt: nil
        )
    }
}

/// Thin facade over APIClient for the practice flow: the paper list
/// (机考题库 papers only), per-paper question fetching with local
/// classification, and best-effort attempt ending.
///
/// Attempt lifecycle (mirrors the collector's collectRound):
///   - entering a wfs=1 paper creates a fresh upstream attempt; the app never
///     submits answers (practice is graded locally), but ends the attempt via
///     endAttempt when the practice session closes. Practice papers answer
///     exam_ending with a JSON success instead of a result page, so
///     submitExam reports "考试未能结束" — that is the expected, swallowed
///     outcome (the attempt did end upstream).
///   - wfs=0 papers are someone's in-progress attempt: entered read-only,
///     never ended.
@MainActor
final class PracticeUpstreamClient {

    private let api: APIClient
    /// Attempts this app session created via wfs=1 enters (paper id → session).
    private(set) var enteredSessions: [Int: ExamSession] = [:]

    init(api: APIClient) {
        self.api = api
    }

    /// The practice paper list: 机考题库 papers whose name carries a category.
    func paperList() async throws -> [Exam] {
        try await api.examList().exams.filter(PracticeMapping.isTargetExam)
    }

    /// Enter a paper and fetch all its questions, joined with the answer-card
    /// sections and classified. `exam.isNew` enters create a tracked attempt.
    func enterPaper(_ exam: Exam) async throws -> [BankQuestion] {
        let session = try await api.enterExam(exam)
        guard let category = PracticeMapping.matchCategory(exam.name) else {
            throw APIError.invalidResponse
        }
        let dtos = try await api.fetchQuestionDTOs(session)
        let questions = PracticeMapping.join(questions: dtos, states: session.questionStates)
            .map { PracticeMapping.bankQuestion(dto: $0.question, section: $0.section, category: category, paperName: exam.name) }
        if exam.isNew {
            enteredSessions[exam.id] = session
        }
        return questions
    }

    /// Best-effort end of an attempt this app created (fire-and-forget, all
    /// errors ignored). No-op for wfs=0 papers and untracked sessions.
    func endAttempt(paper: Exam) {
        guard paper.isNew, let session = enteredSessions.removeValue(forKey: paper.id) else { return }
        Task { try? await api.submitExam(examInfoId: String(paper.id), session: session) }
    }

    // MARK: - Full-bank crawl

    /// One paper's crawl progress (shown by the practice download gate).
    struct CrawlProgress: Sendable, Equatable {
        let index: Int // 1-based, papers already done
        let total: Int
        let paperName: String
    }

    /// Crawl every 机考题库 paper into the local bank — the iOS port of the
    /// collector's runCollection, crash-safe per paper:
    ///   - papers already marked done in meta.papers are skipped (resume);
    ///   - each new paper is entered (wfs=1 creates a fresh attempt which is
    ///     best-effort-ended after fetching; wfs=0 is read-only, never ended);
    ///   - records are deduped by _id against the stored bank, appended per
    ///     category, and meta.json (papers + counts) is saved after every
    ///     paper, so an interruption resumes without re-entering anything.
    func crawlAllPapers(storage: BankStorage, progress: @escaping (CrawlProgress) -> Void) async throws {
        let papers = try await paperList()
        guard !papers.isEmpty else {
            // Nothing to crawl — still record the attempt so the store is
            // marked populated with a valid (empty) meta.
            try storage.saveMeta(BankMeta(version: 1, round: 1, lastRun: Self.timestamp(), targets: BankLogic.categories, counts: [:], papers: [:]))
            return
        }
        var meta = storage.loadMeta() ?? BankMeta(version: 1, targets: BankLogic.categories)
        var counts = meta.counts ?? [:]
        var seenIds = Self.loadSeenIds(storage: storage)

        for (index, paper) in papers.enumerated() {
            let paperId = String(paper.id)
            if meta.papers?[paperId] == true { continue }

            let records = try await enterPaper(paper)
            var newRecords: [BankQuestion] = []
            var byCategory: [String: [BankQuestion]] = [:]
            for record in records {
                guard !seenIds.contains(record.id) else { continue }
                seenIds.insert(record.id)
                newRecords.append(record)
                byCategory[record.category, default: []].append(record)
            }
            for (category, categoryRecords) in byCategory {
                try storage.appendRecords(categoryRecords, for: category)
                counts[category, default: 0] += categoryRecords.count
            }
            endAttempt(paper: paper)

            var papers = meta.papers ?? [:]
            papers[paperId] = true
            meta = BankMeta(
                version: 1,
                round: meta.round,
                lastRun: meta.lastRun,
                targets: BankLogic.categories,
                counts: counts,
                papers: papers
            )
            try storage.saveMeta(meta)
            progress(CrawlProgress(index: index + 1, total: papers.count, paperName: paper.name))
        }

        meta = BankMeta(
            version: 1,
            round: (meta.round ?? 0) + 1,
            lastRun: Self.timestamp(),
            targets: BankLogic.categories,
            counts: counts,
            papers: meta.papers
        )
        try storage.saveMeta(meta)
    }

    /// All stored record ids across the target categories (dedupe set).
    private static func loadSeenIds(storage: BankStorage) -> Set<String> {
        var ids = Set<String>()
        for category in BankLogic.categories {
            guard let text = storage.loadCategoryText(category) else { continue }
            for question in BankLogic.parseJSONL(text) {
                ids.insert(question.id)
            }
        }
        return ids
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
