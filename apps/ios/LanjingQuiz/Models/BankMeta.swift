import Foundation

/// Persisted in the bank's meta.json. counts (per-category) match the JSONL
/// line counts exactly and are the category-list data source. `targets` is
/// informational only — the web collector once wrote a typo there
/// ("语言理解" vs the real file 言语理解.jsonl), so the client never derives
/// file names from it. `papers` records the crawled paper ids (value true) so
/// an interrupted crawl resumes without re-entering completed papers.
struct BankMeta: Codable, Equatable, Sendable {
    let version: Int?
    let round: Int?
    let lastRun: String?
    let targets: [String]?
    let counts: [String: Int]?
    let papers: [String: Bool]?

    init(
        version: Int? = nil,
        round: Int? = nil,
        lastRun: String? = nil,
        targets: [String]? = nil,
        counts: [String: Int]? = nil,
        papers: [String: Bool]? = nil
    ) {
        self.version = version
        self.round = round
        self.lastRun = lastRun
        self.targets = targets
        self.counts = counts
        self.papers = papers
    }

    var totalCount: Int { counts?.values.reduce(0, +) ?? 0 }
}
