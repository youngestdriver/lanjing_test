import Foundation

/// One practice question, built from an upstream QuestionDTO + answer-card
/// state (see PracticeMapping.bankQuestion). The answer is a letter or letter
/// array (or nil when unknown); keys are derived from the letters so grading
/// stays uniform. Formula images stay remote — only protocol-relative srcs
/// are normalized at construction time.
struct BankQuestion: Identifiable, Equatable, Sendable {

    /// "A" | ["A","C"] | nil. nil → the record has no known answer.
    struct Answer: Equatable, Sendable {
        let letters: [String]

        init(letters: [String]) {
            self.letters = letters
        }
    }

    let id: String // _id
    let category: String
    let section: String // coarser group, e.g. 逻辑填空 (kept for metadata display)
    let subCategory: String // 题型细分, e.g. 加强支持 — the practice grouping key
    let question: String // HTML, img srcs normalized at construction time
    let options: [String] // all 4 slots preserved; empty strings = 填空 slots
    let answer: Answer?
    let analysis: String?
    let sourceExamName: String?
    let round: Int?
    let collectedAt: String? // raw ISO8601 string, no date parsing needed

    /// "ABCD" prefix matching the preserved option slots.
    var letters: [String] {
        Array("ABCD".prefix(options.count)).map(String.init)
    }

    /// Correct-flag per letter slot (all false when the answer is unknown).
    var keys: [Bool] {
        letters.map { answer?.letters.contains($0) ?? false }
    }

    /// More than one correct letter (the option count is always 4).
    var isMulti: Bool { (answer?.letters.count ?? 0) > 1 }
    var correctAnswers: [String] { answer?.letters ?? [] }
    var isGradable: Bool { answer != nil }

    /// Protocol-relative img srcs ("//host/...") → "https://host/...".
    /// Absolute https URLs (fb.fbstatic.cn, test.lanjingweike.com) pass
    /// through unchanged. Current bank data has no http:// srcs; if future
    /// collection introduces them, WKWebView's mixed-content policy would
    /// block them (document base is https) — only "//" is repaired here.
    static func normalizeImgSrcs(_ html: String) -> String {
        html
            .replacingOccurrences(of: "src=\"//", with: "src=\"https://")
            .replacingOccurrences(of: "src='//", with: "src='https://")
    }

    init(
        id: String, category: String, section: String, subCategory: String,
        question: String, options: [String], answer: Answer?,
        analysis: String?, sourceExamName: String?, round: Int?, collectedAt: String?
    ) {
        self.id = id
        self.category = category
        self.section = section
        self.subCategory = subCategory
        self.question = Self.normalizeImgSrcs(question)
        self.options = options
        self.answer = answer
        self.analysis = analysis.map(Self.normalizeImgSrcs)
        self.sourceExamName = sourceExamName
        self.round = round
        self.collectedAt = collectedAt
    }
}
