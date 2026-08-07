import Foundation

/// Pure, nonisolated practice-bank helpers so unit tests never need the VM.
enum BankLogic {

    /// The 5 机考 categories; file base names in apps/bank. Fixed list —
    /// never derived from meta.json targets (see BankMeta's note).
    static let categories: [String] = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"]

    /// Split text on "\n" and decode each non-empty line; malformed lines are
    /// dropped (the collector guarantees only the trailing line may be corrupt).
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
