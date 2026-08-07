import Foundation

/// Injectable bank persistence. The fake protocol lets VM tests run without
/// touching the file system (same seam as CookiePersistence).
protocol BankStorage: Sendable {
    /// meta exists AND all 5 category files exist.
    func isPopulated() -> Bool
    func loadMeta() -> BankMeta?
    func loadCategoryText(_ category: String) -> String?
    /// Write every file, then meta LAST as the commit point.
    func saveAll(files: [(category: String, text: String)], meta: BankMeta) throws
    func removeAll() throws
}

/// FileManager-backed storage: Application Support/LanjingQuiz/bank/.
/// Atomic writes; the meta file written last means an interrupted update
/// leaves the store unpopulated (isPopulated == false) and the next entry
/// re-downloads cleanly.
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
        // Commit point: meta last.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    func removeAll() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
