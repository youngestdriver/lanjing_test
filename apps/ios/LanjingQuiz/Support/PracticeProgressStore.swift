import Foundation

/// Injectable persistence seam for per-subcategory practice progress
/// (mirrors PracticeSessionStoring).
protocol PracticeProgressStoring: Sendable {
    /// nil = 无存档(从未做过任何题或已清除)。
    func load() async -> [String: PracticeProgress]?
    func save(_ progress: [String: PracticeProgress]) async throws
    func clear() async throws
}

/// Answered-progress for one 题型细分. Keyed in the registry file by
/// "\(category)/\(subCategory)" — the category aggregate sums the prefix.
struct PracticeProgress: Codable, Equatable, Sendable {
    var answeredIDs: [String] = [] // 已揭晓答案的题目 _id(稳定,不受随机顺序影响)
}

/// FileManager-backed: Application Support/LanjingQuiz/practice-progress.json。
/// actor 串行化 save/load(镜像 FileManagerPracticeSessionStore)。
actor FileManagerPracticeProgressStore: PracticeProgressStoring {

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/practice-progress.json")
    }

    func load() async -> [String: PracticeProgress]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: PracticeProgress].self, from: data)
    }

    func save(_ progress: [String: PracticeProgress]) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(progress).write(to: url, options: .atomic)
    }

    func clear() async throws {
        try? FileManager.default.removeItem(at: url)
    }
}
