import Foundation

/// One exam question with derived correct-answer fields — port of the server-side
/// enrichment in server.js fetchAllQuestions (_isMulti / _answers / _answerHtml / _analysis).
struct Question: Identifiable, Equatable {
    let id: String
    let text: String
    let answers: [String]
    let keys: [Bool]
    let testAnsRight: String
    let analysis: String?

    init(dto: QuestionDTO) {
        self.id = dto._id
        self.text = dto.question
        var options: [String] = []
        var flags: [Bool] = []
        for (answer, key) in [(dto.answer1, dto.key1), (dto.answer2, dto.key2), (dto.answer3, dto.key3), (dto.answer4, dto.key4)] {
            if let answer, !answer.isEmpty {
                options.append(answer)
                flags.append(key == "1")
            }
        }
        self.answers = options
        self.keys = flags
        self.testAnsRight = dto.test_ans_right ?? ""
        self.analysis = dto.analysis
    }

    /// A, B, C, D — one per answer.
    var letters: [String] { Array("ABCD".prefix(answers.count)).map(String.init) }

    var isMulti: Bool { keys.filter { $0 }.count > 1 }

    /// Correct letters, in A→D order (port of _answers).
    var correctAnswers: [String] {
        zip(letters, keys).filter { $0.1 }.map { $0.0 }
    }

    /// Port of _answer: first correct letter, fallback test_ans_right, then "?".
    var firstAnswer: String {
        if let first = correctAnswers.first { return first }
        return testAnsRight.isEmpty ? "?" : testAnsRight
    }

    /// Port of _answerHtml: correct option HTML joined with <br>.
    var answerHtml: String {
        correctAnswers.compactMap { letter in
            guard let idx = letters.firstIndex(of: letter), idx < answers.count else { return nil }
            return answers[idx]
        }
        .joined(separator: "<br>")
    }

    /// Horizontal keycap layout when exactly 4 options and every option text ≤ 2 chars
    /// (SPA renderQuestion optTexts check). Image options and empty options are excluded.
    var isCompactLayout: Bool {
        answers.count == 4 && answers.allSatisfy { answer in
            guard answer.range(of: "<img", options: .caseInsensitive) == nil else { return false }
            let text = Self.plainText(answer).trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.count <= 2
        }
    }

    func isCorrectAnswer(_ letter: String) -> Bool {
        correctAnswers.contains(letter)
    }

    /// All options are image-based (逻辑推理 with picture sequences): the option
    /// content duplicates the stem, so only the A/B/C/D letters are shown.
    var isImageOptions: Bool {
        !answers.isEmpty && answers.allSatisfy { $0.range(of: "<img", options: .caseInsensitive) != nil }
    }

    /// 逻辑推理-style layout: four compact tiles pinned side by side at the bottom.
    var isLogicLayout: Bool {
        isCompactLayout || isImageOptions
    }

    /// Port of the SPA letter→key mapping (A→1 … D→4). Trailing comma is mandatory
    /// upstream: single "key1,", multi "key1,key3,".
    static func answerKey(for letter: String) -> String? {
        switch letter {
        case "A": "key1,"
        case "B": "key2,"
        case "C": "key3,"
        case "D": "key4,"
        default: nil
        }
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
