import Foundation

/// Downloads the question bank from a plain-HTTP source: 5 category JSONL
/// files + meta.json, fetched directly from the configured server
/// (no API indirection — the web server serves apps/bank statically at /bank).
///
/// Uses its own ephemeral session so bank traffic never mixes with the app's
/// lanjingweike cookie jar (same isolation as CookieCloudClient). Formula
/// images inside question HTML are deliberately NOT downloaded — they render
/// remotely through WKWebView.
struct QuestionBankClient: Sendable {

    enum BankError: Swift.Error, LocalizedError {
        case invalidServerURL
        case httpStatus(Int)
        case notUTF8
        case malformedMeta

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: "题库服务器地址无效（需 http:// 或 https://）"
            case .httpStatus(let status): "下载失败（HTTP \(status)），请检查服务器是否已启动、题库服务器地址是否正确"
            case .notUTF8: "题库文件不是有效的 UTF-8 文本"
            case .malformedMeta: "meta.json 无法解析，题库可能不完整"
            }
        }
    }

    /// Per-file download progress (6 steps: meta.json + 5 categories).
    struct Progress: Sendable, Equatable {
        let fileIndex: Int // 0-based
        let fileCount: Int
        let fileName: String
    }

    /// Everything needed to persist the bank in one commit.
    struct Result: Sendable {
        let files: [(category: String, text: String)]
        let meta: BankMeta
    }

    private let fetch: @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    init(session: URLSession = QuestionBankClient.makeSession()) {
        self.fetch = { url in
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw BankError.httpStatus(-1)
            }
            return (data, http)
        }
    }

    /// Test seam: inject a loader that never touches the network.
    init(fetch: @escaping @Sendable (URL) async throws -> (Data, HTTPURLResponse)) {
        self.fetch = fetch
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    func fetchMeta(from baseURL: URL) async throws -> BankMeta {
        let (data, _) = try await fetch(baseURL.appending(path: "bank/meta.json"))
        guard let meta = try? JSONDecoder().decode(BankMeta.self, from: data) else {
            throw BankError.malformedMeta
        }
        return meta
    }

    /// Download meta.json first (cheap liveness probe), then each category
    /// JSONL in fixed order. All files land in memory (~12 MB) before any
    /// storage write — a mid-download failure leaves the previous bank
    /// untouched.
    func downloadBank(
        from baseURL: URL,
        categories: [String] = BankLogic.categories,
        progress: @Sendable (Progress) -> Void
    ) async throws -> Result {
        let filesCount = categories.count + 1 // meta + 5 categories
        let meta = try await fetchMeta(from: baseURL)
        progress(Progress(fileIndex: 0, fileCount: filesCount, fileName: "meta.json"))

        var files: [(category: String, text: String)] = []
        for (index, category) in categories.enumerated() {
            let url = baseURL.appending(path: "bank/\(category).jsonl")
            let (data, response) = try await fetch(url)
            guard response.statusCode == 200 else { throw BankError.httpStatus(response.statusCode) }
            guard let text = String(data: data, encoding: .utf8) else { throw BankError.notUTF8 }
            files.append((category: category, text: text))
            progress(Progress(fileIndex: index + 1, fileCount: filesCount, fileName: "\(category).jsonl"))
        }
        return Result(files: files, meta: meta)
    }
}
