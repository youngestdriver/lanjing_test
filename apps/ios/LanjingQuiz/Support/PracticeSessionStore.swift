import Foundation

/// Injectable persistence seam for the practice session (mirrors BankStorage,
/// so VM unit tests run with a fake and never touch the file system).
protocol PracticeSessionStoring: Sendable {
    /// nil = 无存档(首次进入或已清除)。
    func load() async -> PracticeSession?
    func save(_ session: PracticeSession) async throws
    func clear() async throws
}

/// FileManager-backed: Application Support/LanjingQuiz/practice-session.json。
/// actor 串行化 save/load,快速连续变异不会乱序落地(每拍抓拍快照,后写赢);
/// JSON 编解码(题干含多 KB HTML)在 actor executor 上执行,不阻塞主线程。
/// FileManager.default 线程安全,无需额外锁。
actor FileManagerPracticeSessionStore: PracticeSessionStoring {

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/practice-session.json")
    }

    func load() async -> PracticeSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PracticeSession.self, from: data)
    }

    func save(_ session: PracticeSession) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: url, options: .atomic)
    }

    func clear() async throws {
        try? FileManager.default.removeItem(at: url)
    }
}
