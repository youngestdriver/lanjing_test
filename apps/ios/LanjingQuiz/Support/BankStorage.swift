import Foundation

/// Injectable local question-bank persistence ("本地数据库"): one JSONL file
/// per category plus meta.json as the commit point — the same on-disk format
/// as the collector's apps/bank/data. The fake protocol lets VM tests run
/// without touching the file system (same seam as CookiePersistence).
protocol BankStorage: Sendable {
    /// meta exists AND all 5 category files exist.
    func isPopulated() -> Bool
    func loadMeta() -> BankMeta?
    func loadCategoryText(_ category: String) -> String?
    /// Write every file, then meta LAST as the commit point.
    func saveAll(files: [(category: String, text: String)], meta: BankMeta) throws
    /// Append records to one category file (read-modify-write, atomic) — the
    /// incremental crawl path, crash-safe per paper.
    func appendRecords(_ records: [BankQuestion], for category: String) throws
    /// Write meta.json atomically — persisted after every crawled paper so a
    /// later resume skips completed papers.
    func saveMeta(_ meta: BankMeta) throws
    func removeAll() throws
    /// Crawl log (crawl_log.jsonl): every paper's steps with outcomes, used by
    /// 我的 > 题库 > 日志导出. Append-only; loadCrawlLog returns [] when the
    /// file does not exist. Default implementations are no-ops so fakes stay
    /// minimal.
    func loadCrawlLog() -> [PracticeUpstreamClient.CrawlLogEntry]
    func appendCrawlLog(_ entries: [PracticeUpstreamClient.CrawlLogEntry]) throws
}

extension BankStorage {
    func loadCrawlLog() -> [PracticeUpstreamClient.CrawlLogEntry] { [] }
    func appendCrawlLog(_ entries: [PracticeUpstreamClient.CrawlLogEntry]) throws {}
}

/// A single record that could not be encoded — the id names the exact
/// question so the crawl log can point at it.
enum BankSaveError: LocalizedError, Equatable {
    case recordEncodeFailed(id: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .recordEncodeFailed(let id, let reason):
            "题目 \(id) 保存失败：\(reason)"
        }
    }
}

/// FileManager-backed storage: Application Support/LanjingQuiz/bank/.
/// Atomic writes; the meta file written last means an interrupted update
/// leaves the store unpopulated (isPopulated == false) and the next entry
/// crawls cleanly.
struct FileManagerBankStorage: BankStorage, Sendable {

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/bank", directoryHint: .isDirectory)
    }

    private func fileURL(for category: String) -> URL {
        directory.appending(path: "\(category).jsonl")
    }

    private var metaURL: URL { directory.appending(path: "meta.json") }

    private var crawlLogURL: URL { directory.appending(path: "crawl_log.jsonl") }

    func loadCrawlLog() -> [PracticeUpstreamClient.CrawlLogEntry] {
        guard let data = try? Data(contentsOf: crawlLogURL), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(PracticeUpstreamClient.CrawlLogEntry.self, from: data)
            }
    }

    func appendCrawlLog(_ entries: [PracticeUpstreamClient.CrawlLogEntry]) throws {
        guard !entries.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var lines = ""
        for entry in entries {
            if let json = String(data: try encoder.encode(entry), encoding: .utf8), !json.isEmpty {
                lines += json + "\n"
            }
        }
        var existing = Data()
        if FileManager.default.fileExists(atPath: crawlLogURL.path) {
            existing = try Data(contentsOf: crawlLogURL)
        }
        try (existing + Data(lines.utf8)).write(to: crawlLogURL, options: .atomic)
    }

    func isPopulated() -> Bool {
        guard let meta = loadMeta() else { return false }
        let files = BankLogic.categories.allSatisfy { category in
            FileManager.default.fileExists(atPath: fileURL(for: category).path)
        }
        return files && !(meta.counts ?? [:]).isEmpty
    }

    func loadMeta() -> BankMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(BankMeta.self, from: data)
    }

    func loadCategoryText(_ category: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: category)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveAll(files: [(category: String, text: String)], meta: BankMeta) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data(file.text.utf8).write(to: fileURL(for: file.category), options: .atomic)
        }
        try saveMeta(meta)
    }

    func appendRecords(_ records: [BankQuestion], for category: String) throws {
        guard !records.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var lines = ""
        for record in records {
            let json: String
            do {
                guard let encoded = String(data: try encoder.encode(record), encoding: .utf8), !encoded.isEmpty else {
                    throw BankSaveError.recordEncodeFailed(id: record.id, reason: "编码结果为空")
                }
                json = encoded
            } catch let error as BankSaveError {
                throw error
            } catch {
                throw BankSaveError.recordEncodeFailed(id: record.id, reason: String(describing: error))
            }
            lines += json + "\n"
        }
        let url = fileURL(for: category)
        var existing = Data()
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try Data(contentsOf: url)
        }
        try (existing + Data(lines.utf8)).write(to: url, options: .atomic)
    }

    func saveMeta(_ meta: BankMeta) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    func removeAll() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
