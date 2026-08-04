import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class QuizViewModel {
    enum TimerMode: Equatable {
        case active, paused, expired
    }

    let exam: Exam

    private(set) var session: ExamSession?
    private(set) var questions: [Question] = []
    private(set) var states: [QuestionState] = []
    private(set) var answeredIDs: Set<String> = []
    var markedByID: [String: Bool] = [:]
    var currentIndex = 0
    /// Keyboard/highlight selection per question, separate from submission (SPA
    /// selectedOptionByQuestion). For multi questions this is the pending tap set.
    var selectionByQuestion: [String: Set<String>] = [:]
    var selectedSection: String?
    var isAnswerCardExpanded = false
    var isSubmitting = false
    var result: ExamResult?
    var errorMessage: String?
    var loadPhase: String?
    private(set) var isLoading = false

    // Timer state
    private var remainingByQuestion: [String: Int] = [:]
    private var timerTask: Task<Void, Never>?
    /// Identifies the one timer task that is allowed to publish UI state.
    /// Navigation can move A → B → A, so a question ID alone is not enough
    /// to distinguish an old task from the newly-started task for the same
    /// question.
    private var timerRunID = 0
    private(set) var displayedSeconds = 60
    private(set) var timerMode: TimerMode = .paused

    // Stale-jump guard: manual navigation invalidates pending auto-advance
    private var generation = 0
    private var autoAdvanceTask: Task<Void, Never>?

    private let appState: AppState

    init(exam: Exam, appState: AppState) {
        self.exam = exam
        self.appState = appState
    }

    // MARK: - Derived state

    var currentQuestion: Question? {
        guard currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    var currentState: QuestionState? {
        guard let question = currentQuestion else { return nil }
        return states.first { $0.questionsId == question.id }
    }

    var totalCount: Int { questions.count }

    var progress: Double {
        totalCount == 0 ? 0 : Double(currentIndex + 1) / Double(totalCount)
    }

    var stats: (right: Int, error: Int, unanswered: Int) {
        var right = 0, error = 0, unanswered = 0
        for state in states {
            switch state.state {
            case .right: right += 1
            case .error: error += 1
            case .unanswered: unanswered += 1
            }
        }
        return (right, error, unanswered)
    }

    var sectionTitles: [String] { session?.sectionOrder ?? [] }

    var isCurrentAnswered: Bool {
        guard let question = currentQuestion else { return true }
        return answeredIDs.contains(question.id)
    }

    // MARK: - Load

    func enterAndLoad() async {
        guard session == nil else { return }
        isLoading = true
        loadPhase = "进入考试…"
        defer {
            isLoading = false
            loadPhase = nil
        }
        do {
            let session = try await appState.api.enterExam(exam)
            self.session = session
            self.states = session.questionStates
            loadPhase = "加载题目…"
            let questions = try await appState.api.fetchQuestions(session)
            self.questions = questions
            // /exam/get_question_info/ returns the user's prior selection in
            // `test_ans` (e.g. "key3,"). Restore it before the first render so
            // answered questions can mark the selected wrong option as ❌.
            selectionByQuestion = Dictionary(
                uniqueKeysWithValues: questions.compactMap { question in
                    let selected = question.previousAnswers
                    return selected.isEmpty ? nil : (question.id, selected)
                }
            )
            answeredIDs = Set(states.filter { $0.state != .unanswered }.map(\.questionsId))
            if let firstUnanswered = states.firstIndex(where: { $0.state == .unanswered }) {
                currentIndex = firstUnanswered
            }
            indexDidChange()
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = apiError.message
            }
        }
    }

    func cancel() {
        stopTimer()
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
    }

    /// Reset a failed load so the user can retry entering the exam.
    func retry() {
        session = nil
        questions = []
        states = []
        answeredIDs = []
        errorMessage = nil
        result = nil
    }

    // MARK: - Navigation

    func goTo(_ index: Int) {
        guard index >= 0, index < states.count, index != currentIndex else { return }
        currentIndex = index
        indexDidChange()
    }

    /// Called whenever currentIndex changes (programmatic or TabView swipe).
    func indexDidChange() {
        generation += 1
        restartTimerForCurrent()
    }

    // MARK: - Answering

    /// Single-select: immediate submit (web parity). Multi-select: toggle pending set.
    func tapOption(_ letter: String) {
        guard let question = currentQuestion, !answeredIDs.contains(question.id) else { return }
        if question.isMulti {
            var selected = selectionByQuestion[question.id, default: []]
            if selected.contains(letter) {
                selected.remove(letter)
            } else {
                selected.insert(letter)
            }
            selectionByQuestion[question.id] = selected
        } else {
            submitAnswer(letters: [letter], correct: question.isCorrectAnswer(letter), question: question)
        }
    }

    /// Multi-select confirm: correct only when the selected set equals the answer set.
    func confirmSelection() {
        guard let question = currentQuestion, question.isMulti, !answeredIDs.contains(question.id) else { return }
        let selected = selectionByQuestion[question.id, default: []]
        guard !selected.isEmpty else { return }
        let ordered = ["A", "B", "C", "D"].filter { selected.contains($0) }
        let correct = QuizLogic.isMultiSelectionCorrect(selected: Set(ordered), correct: Set(question.correctAnswers))
        submitAnswer(letters: ordered, correct: correct, question: question)
    }

    /// Keyboard highlight (single) / toggle (multi); Enter submits via submitCurrentSelection.
    func selectOption(_ letter: String) {
        guard let question = currentQuestion, !answeredIDs.contains(question.id) else { return }
        if question.isMulti {
            tapOption(letter)
        } else {
            selectionByQuestion[question.id] = [letter]
        }
    }

    func submitCurrentSelection() {
        guard let question = currentQuestion, !answeredIDs.contains(question.id) else { return }
        if question.isMulti {
            confirmSelection()
        } else if let letter = selectionByQuestion[question.id]?.first {
            submitAnswer(letters: [letter], correct: question.isCorrectAnswer(letter), question: question)
        } else {
            goTo(QuizLogic.nextIndex(after: currentIndex, states: states))
        }
    }

    /// ArrowLeft/ArrowRight: move selection among options with wraparound.
    func moveSelection(direction: Int) {
        guard let question = currentQuestion, !answeredIDs.contains(question.id), !question.isMulti else { return }
        let options = question.letters
        guard !options.isEmpty else { return }
        let current = selectionByQuestion[question.id]?.first
        let nextPos: Int
        if let current, let pos = options.firstIndex(of: current) {
            nextPos = (pos + direction + options.count) % options.count
        } else {
            nextPos = direction > 0 ? 0 : options.count - 1
        }
        selectionByQuestion[question.id] = [options[nextPos]]
    }

    func clearSelection() {
        guard let question = currentQuestion else { return }
        selectionByQuestion.removeValue(forKey: question.id)
    }

    // MARK: - Mark

    func toggleMark() {
        guard let question = currentQuestion, let session else { return }
        let newValue = !(markedByID[question.id] ?? false)
        setMarked(question.id, newValue)
        Task {
            do {
                try await appState.api.toggleMark(session: session, testId: question.id, isMark: newValue)
            } catch {
                appState.handle(error)
                if let apiError = error as? APIError,
                   apiError != .sessionExpired, apiError != .notLoggedIn {
                    setMarked(question.id, !newValue)
                }
            }
        }
    }

    // MARK: - Sections

    func selectSectionTab(_ section: String?) {
        selectedSection = section
        if let section { jumpToSection(section) }
    }

    func jumpToSection(_ section: String) {
        if let first = states.firstIndex(where: { $0.section == section && $0.state == .unanswered }) {
            goTo(first)
        } else if let first = states.firstIndex(where: { $0.section == section }) {
            goTo(first)
        }
    }

    // MARK: - Submit exam

    func submitExam() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let r = try await appState.api.submitExam(examInfoId: String(exam.id), session: session)
            result = r
        } catch {
            if Task.isCancelled { return }
            appState.handle(error)
            if let apiError = error as? APIError,
               apiError != .sessionExpired, apiError != .notLoggedIn {
                errorMessage = apiError.message
            }
        }
    }

    // MARK: - Private

    /// Cancels the current countdown and invalidates any in-flight tick before
    /// another task can be started. The run ID prevents a cancelled task from
    /// clearing or overwriting the replacement task's state.
    private func stopTimer() {
        timerRunID &+= 1
        timerTask?.cancel()
        timerTask = nil
    }

    private func setMarked(_ id: String, _ value: Bool) {
        markedByID[id] = value
        if let idx = states.firstIndex(where: { $0.questionsId == id }) {
            states[idx].marked = value
        }
    }

    /// Port of the SPA selectOpt: update state, stop timer, reveal explain banner,
    /// fire-and-forget the upstream report, auto-advance only on correct answers.
    private func submitAnswer(letters: [String], correct: Bool, question: Question) {
        if let idx = states.firstIndex(where: { $0.questionsId == question.id }) {
            states[idx].state = correct ? .right : .error
        }
        answeredIDs.insert(question.id)
        selectionByQuestion[question.id] = Set(letters)
        stopTimer()
        timerMode = .paused
        displayedSeconds = 60

        if let session {
            let testAns = letters.compactMap { Question.answerKey(for: $0) }.joined()
            Task {
                do {
                    try await appState.api.submitAnswer(session: session, testId: question.id, testAns: testAns, correct: correct)
                } catch {
                    appState.handle(error)
                }
            }
        }
        if correct && appState.autoAdvanceOnCorrect {
            scheduleAutoAdvance()
        }
    }

    private func scheduleAutoAdvance() {
        autoAdvanceTask?.cancel()
        let token = generation
        autoAdvanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled else { return }
            guard token == self.generation else { return }
            let target = QuizLogic.nextIndex(after: self.currentIndex, states: self.states)
            if target != self.currentIndex {
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.goTo(target)
                }
            }
        }
    }

    private func restartTimerForCurrent() {
        stopTimer()
        guard let question = currentQuestion else {
            timerMode = .paused
            return
        }
        if answeredIDs.contains(question.id) {
            // Web parity: answered questions show a paused 01:00
            timerMode = .paused
            displayedSeconds = 60
            return
        }
        let remaining = remainingByQuestion[question.id] ?? 60
        if remaining <= 0 {
            timerMode = .expired
            displayedSeconds = 0
            return
        }
        timerMode = .active
        displayedSeconds = remaining
        let qId = question.id
        let runID = timerRunID
        timerTask = Task { [weak self] in
            var seconds = remaining
            while seconds > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Switching questions or leaving the quiz cancels this
                    // task. A cancelled task must never publish one more tick.
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      self.timerRunID == runID,
                      self.currentQuestion?.id == qId,
                      !self.answeredIDs.contains(qId) else {
                    return
                }
                seconds -= 1
                self.remainingByQuestion[qId] = seconds
                self.displayedSeconds = seconds
                if seconds == 0 {
                    self.timerMode = .expired
                    self.timerTask = nil
                    return
                }
            }
        }
    }
}
