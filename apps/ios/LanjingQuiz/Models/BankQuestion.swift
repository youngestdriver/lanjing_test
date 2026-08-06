import Foundation

/// One bank record, decoded from a single apps/bank/*.jsonl line.
///
/// Unlike the exam Question (keyN flags), bank records carry the answer as a
/// letter or letter array (or null when unknown); keys are derived from the
/// letters so grading stays uniform. Formula images stay remote — only
/// protocol-relative srcs are normalized at decode time.
struct BankQuestion: Identifiable, Equatable, Decodable, Sendable {

    /// answer: "A" | ["A","C"] | null. null → the record has no known answer.
    struct Answer: Decodable, Equatable, Sendable {
        let letters: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                letters = [single]
            } else if let array = try? container.decode([String].self) {
                letters = array
            } else {
                // JSON null decodes as nil at the answer field (try? at the
                // call site); any other shape is a malformed record.
                throw DecodingError.typeMismatch(
                    Answer.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "answer must be a string, an array of strings, or null"
                    )
                )
            }
        }

        init(letters: [String]) {
            self.letters = letters
        }
    }

    let id: String // _id
    let category: String
    let section: String // coarser group, e.g. 逻辑判断 (kept for metadata display)
    let subCategory: String // 题型细分, e.g. 加强支持 — the practice grouping key
    let question: String // HTML, img srcs normalized at decode time
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

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case category
        case section
        case subCategory
        case question
        case options
        case answer
        case analysis
        case sourceExamName
        case round
        case collectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            category: (try? container.decode(String.self, forKey: .category)) ?? "",
            section: (try? container.decode(String.self, forKey: .section)) ?? "",
            subCategory: (try? container.decode(String.self, forKey: .subCategory)) ?? "",
            question: (try? container.decode(String.self, forKey: .question)) ?? "",
            options: (try? container.decode([String].self, forKey: .options)) ?? [],
            answer: try? container.decode(Answer.self, forKey: .answer),
            analysis: try? container.decode(String.self, forKey: .analysis),
            sourceExamName: try? container.decode(String.self, forKey: .sourceExamName),
            round: try? container.decode(Int.self, forKey: .round),
            collectedAt: try? container.decode(String.self, forKey: .collectedAt)
        )
    }
}
