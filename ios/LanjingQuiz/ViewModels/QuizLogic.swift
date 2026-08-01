import Foundation

/// Pure, nonisolated quiz helpers so unit tests never need the MainActor VM.
enum QuizLogic {

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
