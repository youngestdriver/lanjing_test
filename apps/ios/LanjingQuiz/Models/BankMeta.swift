import Foundation

/// Decoded from the bank's meta.json. counts (per-category) match the JSONL
/// line counts exactly and are the category-list data source. `targets` is
/// informational only — the web collector once wrote a typo there
/// ("语言理解" vs the real file 言语理解.jsonl), so the client never derives
/// file names from it.
struct BankMeta: Codable, Equatable, Sendable {
    let version: Int?
    let round: Int?
    let lastRun: String?
    let targets: [String]?
    let counts: [String: Int]?

    var totalCount: Int { counts?.values.reduce(0, +) ?? 0 }
}
