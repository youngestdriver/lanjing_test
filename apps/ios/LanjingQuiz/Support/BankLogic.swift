import Foundation

/// Pure, nonisolated practice-bank helpers so unit tests never need the VM.
enum BankLogic {

    /// The 5 机考 categories (paper-name matching + classifier input).
    static let categories: [String] = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"]

    /// Split text on "\n" and decode each non-empty line; malformed lines are
    /// dropped (the crawler guarantees only the trailing line may be corrupt).
    static func parseJSONL(_ text: String) -> [BankQuestion] {
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(BankQuestion.self, from: data)
            }
    }

    /// Group questions by subCategory, preserving first-appearance order.
    static func groupBySubcategory(_ questions: [BankQuestion]) -> [(name: String, questions: [BankQuestion])] {
        var order: [String] = []
        var groups: [String: [BankQuestion]] = [:]
        for question in questions {
            let key = question.subCategory.isEmpty ? "未分类" : question.subCategory
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(question)
        }
        return order.map { (name: $0, questions: groups[$0] ?? []) }
    }

    /// Grade a submission. nil = the question has no known answer (ungradable).
    /// Single-select: the selected set must equal the answer set.
    /// Multi-select: exact set equality (same semantics as the exam flow).
    static func grade(selected: Set<String>, question: BankQuestion) -> Bool? {
        guard let answer = question.answer, !answer.letters.isEmpty else { return nil }
        return selected == Set(answer.letters)
    }

    /// Result marker for one option row after reveal: selected-but-wrong → .wrong,
    /// correct → .correct, everything else nil. (Bank variant of
    /// QuizLogic.optionResult without a question state.)
    static func optionResult(isAnswered: Bool, isSelected: Bool, isCorrect: Bool) -> QuizLogic.OptionResult? {
        guard isAnswered else { return nil }
        if isSelected && !isCorrect { return .wrong }
        if isCorrect { return .correct }
        return nil
    }

    /// Deterministic shuffle for tests; the VM seeds it randomly per session.
    static func shuffled(_ questions: [BankQuestion], seed: UInt64) -> [BankQuestion] {
        var generator = SeededGenerator(seed: seed)
        return questions.shuffled(using: &generator)
    }

    // MARK: - 日志导出 (crawl-log plain-text export)

    /// Plain-text export of the crawl log for the 我的 > 题库 > 日志导出 row:
    /// one line per step with its outcome (成功/失败/跳过) and message, newest
    /// last, plus a summary header.
    static func exportLogText(_ entries: [PracticeUpstreamClient.CrawlLogEntry]) -> String {
        let successes = entries.filter { $0.outcome == .success }.count
        let failures = entries.filter { $0.outcome == .failure }.count
        let skipped = entries.filter { $0.outcome == .skipped }.count
        var lines = [
            "题库爬取日志（共 \(entries.count) 条）",
            "成功 \(successes) · 失败 \(failures) · 跳过 \(skipped)",
            "",
        ]
        for entry in entries {
            let paper = entry.paperName.isEmpty ? "-" : entry.paperName
            let message = entry.message.map { "（\($0)）" } ?? ""
            lines.append("[\(Self.displayTime(entry.timestamp))] \(paper) · \(entry.step.displayName) — \(entry.outcome.displayName)\(message)")
        }
        return lines.joined(separator: "\n")
    }

    /// ISO8601 timestamp → local "yyyy-MM-dd HH:mm:ss" for the exported log.
    static func displayTime(_ iso8601: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Date-time named export file, e.g. "爬取日志_20260810_1430.txt".
    static func exportFileName(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return "爬取日志_\(formatter.string(from: date)).txt"
    }

    /// SplitMix64 — deterministic, cheap, seedable.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
