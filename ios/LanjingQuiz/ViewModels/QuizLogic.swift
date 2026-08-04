import Foundation

/// Pure, nonisolated quiz helpers so unit tests never need the MainActor VM.
enum QuizLogic {

    enum OptionResult: Equatable {
        case correct
        case wrong
    }

    /// Determines the marker for one option after a result is revealed.
    ///
    /// A wrong single-choice submission is authoritative: the submitted
    /// option is ❌ even if the upstream answer flags are inconsistent. For a
    /// multi-choice question, reference answers remain ✅ and only selected
    /// options outside that reference set are ❌. Unrelated options return nil.
    static func optionResult(
        isAnswered: Bool,
        isSelected: Bool,
        isCorrect: Bool,
        isMulti: Bool,
        questionState: QuestionState.State?
    ) -> OptionResult? {
        guard isAnswered else { return nil }
        if isSelected && ((!isMulti && questionState == .error) || !isCorrect) {
            return .wrong
        }
        if isCorrect { return .correct }
        return nil
    }

    /// Auto-advance target after a correct answer: the first unanswered question
    /// after `index` (wrapping around), else index+1 clamped — port of the SPA's
    /// next-unanswered-or-next-index behavior (index.html:1956-1963).
    static func nextIndex(after index: Int, states: [QuestionState]) -> Int {
        let count = states.count
        guard count > 0 else { return index }
        var i = (index + 1) % count
        while i != index {
            if states[i].state == .unanswered { return i }
            i = (i + 1) % count
        }
        return min(index + 1, count - 1)
    }

    /// True multi-select judgment: the selected set must equal the correct set.
    static func isMultiSelectionCorrect(selected: Set<String>, correct: Set<String>) -> Bool {
        !selected.isEmpty && selected == correct
    }
}
