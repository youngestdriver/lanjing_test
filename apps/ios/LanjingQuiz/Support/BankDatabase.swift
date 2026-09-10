import Foundation
import SwiftData
import UIKit

/// SwiftData-backed offline question bank. The database owns the question
/// metadata and image bytes so practice never needs to fetch remote HTML
/// resources while a question is on screen.
@Model
final class BankVersion {
    @Attribute(.unique) var id: String
    var createdAt: Date
    var questionCount: Int
    var imageCount: Int
    var isCurrent: Bool
    var paperProgressJSON: String

    init(id: String = UUID().uuidString, createdAt: Date = .now,
         questionCount: Int = 0, imageCount: Int = 0, isCurrent: Bool = false,
         paperProgressJSON: String = "{}") {
        self.id = id
        self.createdAt = createdAt
        self.questionCount = questionCount
        self.imageCount = imageCount
        self.isCurrent = isCurrent
        self.paperProgressJSON = paperProgressJSON
    }
}

@Model
final class BankImage {
    @Attribute(.unique) var id: String
    var remoteURL: String
    var mimeType: String
    var width: Int
    var height: Int
    var byteSize: Int
    @Attribute(.externalStorage) var data: Data

    init(id: String, remoteURL: String, mimeType: String = "image/png",
         width: Int = 0, height: Int = 0, data: Data = Data()) {
        self.id = id
        self.remoteURL = remoteURL
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.byteSize = data.count
        self.data = data
    }
}

@Model
final class BankQuestionRecord {
    @Attribute(.unique) var id: String
    var category: String
    var section: String
    var subCategory: String
    var questionHTML: String
    var stemHTML: String
    var analysisHTML: String
    var answerJSON: String?
    var sourceExamName: String
    var round: Int?
    var collectedAt: String?
    var versionID: String
    @Relationship(deleteRule: .cascade) var options: [BankOptionRecord]

    init(from question: BankQuestion, versionID: String) throws {
        self.id = question.id
        self.category = question.category
        self.section = question.section
        self.subCategory = question.subCategory
        self.questionHTML = question.question
        self.stemHTML = question.stem ?? ""
        self.analysisHTML = question.analysis ?? ""
        self.answerJSON = question.answer.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        self.sourceExamName = question.sourceExamName ?? ""
        self.round = question.round
        self.collectedAt = question.collectedAt
        self.versionID = versionID
        self.options = question.options.enumerated().map {
            BankOptionRecord(questionID: question.id, index: $0.offset, html: $0.element)
        }
    }
}

@Model
final class BankOptionRecord {
    var questionID: String
    var index: Int
    var html: String

    init(questionID: String, index: Int, html: String) {
        self.questionID = questionID
        self.index = index
        self.html = html
    }
}

@Model
final class BankCrawlLogRecord {
    var id: UUID
    var timestamp: String
    var paperID: String?
    var paperName: String
    var step: String
    var outcome: String
    var message: String?

    init(entry: PracticeUpstreamClient.CrawlLogEntry) {
        id = UUID()
        timestamp = entry.timestamp
        paperID = entry.paperId
        paperName = entry.paperName
        step = entry.step.rawValue
        outcome = entry.outcome.rawValue
        message = entry.message
    }
}

struct BankDatabase: Sendable {
    let container: ModelContainer
    let imageResolver: BankImageResolver

    @MainActor
    init(inMemory: Bool = false) throws {
        let schema = Schema([
            BankVersion.self,
            BankImage.self,
            BankQuestionRecord.self,
            BankOptionRecord.self,
            BankCrawlLogRecord.self,
        ])
        let configuration = ModelConfiguration(
            "LanjingQuizBank",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )
        container = try ModelContainer(for: schema, configurations: configuration)
        imageResolver = BankImageResolver(container: container)
    }

    @MainActor
    func currentVersion() throws -> BankVersion? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<BankVersion>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first(where: { $0.isCurrent })
    }

    /// Per-category question counts for the current version — the BankMeta
    /// `counts` data source for the category list (per-category rows and the
    /// 共 N 题 footer). Old versions' records are not deleted by
    /// replaceCurrent, so the counts filter by the current version id.
    @MainActor
    func categoryCounts() throws -> [String: Int] {
        let context = ModelContext(container)
        guard let versionID = try currentVersion()?.id else { return [:] }
        let records = try context.fetch(FetchDescriptor<BankQuestionRecord>())
        return Dictionary(grouping: records.filter { $0.versionID == versionID },
                          by: \.category).mapValues { $0.count }
    }

    @MainActor
    func questions(category: String, subCategory: String? = nil) throws -> [BankQuestion] {
        let context = ModelContext(container)
        guard let version = try currentVersion() else { return [] }
        let versionID = version.id
        let categoryValue = category
        let records = try context.fetch(FetchDescriptor<BankQuestionRecord>())
            .filter { $0.versionID == versionID && $0.category == categoryValue }
            .sorted { $0.id < $1.id }
        return records.compactMap { record in
            if let subCategory, record.subCategory != subCategory { return nil }
            let answer = record.answerJSON.flatMap { Data($0.utf8) }.flatMap {
                try? JSONDecoder().decode(BankQuestion.Answer.self, from: $0)
            }
            let options = record.options.sorted { $0.index < $1.index }.map(\.html)
            return BankQuestion(
                id: record.id, category: record.category, section: record.section,
                subCategory: record.subCategory, question: record.questionHTML,
                stem: record.stemHTML.isEmpty ? nil : record.stemHTML, options: options,
                answer: answer, analysis: record.analysisHTML.isEmpty ? nil : record.analysisHTML,
                sourceExamName: record.sourceExamName.isEmpty ? nil : record.sourceExamName,
                round: record.round, collectedAt: record.collectedAt
            )
        }
    }

    @MainActor
    func localizeHTML(_ html: String) -> String {
        imageResolver.localize(html)
    }

    /// 原生图片块直出:从本地库解码(零网络、零 WebView)。
    @MainActor
    func resolverImage(for remoteURL: String) -> UIImage? {
        imageResolver.image(for: remoteURL)
    }

    /// 题图来源:爬取路径逐张下载(网络),导入路径从题库包里抽(零网络)。
    enum BankImageSource {
        case remote
        case package(BankPackage)
    }

    /// 一次整库替换的写入结果。被跳过的图片 URL 必须回传给调用方——静默
    /// 丢弃正是「有的图永远显示不出来」的根因。
    struct BankReplaceOutcome: Equatable, Sendable {
        var imageCount = 0
        var skippedImageURLs: [String] = []
    }

    @MainActor
    @discardableResult
    func replaceCurrent(with groups: [String: [BankQuestion]], papers: [String: Bool] = [:],
                        imageSource: BankImageSource = .remote) async throws -> BankReplaceOutcome {
        let context = ModelContext(container)
        let old = try context.fetch(FetchDescriptor<BankVersion>())
        for version in old { context.delete(version) }
        // 旧题记录/题图与 BankVersion 无关联,不会随版本行级联删除:必须显式
        // 清掉,否则每次 更新题库 都残留一批孤儿记录。顺序也必须是先删后插:
        // 主键(题 _id / 图 URL 的 sha256)是 @Attribute(.unique),重复插入
        // 实测**不抛错而是就地 upsert**(见 testUniqueIDConflictUpsertsInstead
        // OfThrowing)——先插会把旧版本的记录静默改写成新版。
        try context.delete(model: BankQuestionRecord.self)
        try context.delete(model: BankImage.self)
        let progressData = (try? JSONEncoder().encode(papers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let version = BankVersion(questionCount: groups.values.reduce(0) { $0 + $1.count }, isCurrent: true,
                                  paperProgressJSON: progressData)
        context.insert(version)
        for question in groups.values.flatMap({ $0 }) {
            let record = try BankQuestionRecord(from: question, versionID: version.id)
            context.insert(record)
        }
        let questions = groups.values.flatMap { $0 }
        let html = questions.flatMap { [$0.question, $0.stem ?? "", $0.analysis ?? ""] + $0.options }
        let urls = Set(html.flatMap(Self.imageURLs(from:)))
        var packageIndex: [String: BankPackageImageEntry] = [:]
        if case .package(let package) = imageSource {
            for entry in package.imageEntries { packageIndex[entry.url] = entry }
        }
        var outcome = BankReplaceOutcome()
        for url in urls {
            let payload: (data: Data, mimeType: String)?
            switch imageSource {
            case .remote:
                payload = await Self.downloadImage(url)
            case .package(let package):
                payload = Self.packageImage(url, package: package, index: packageIndex)
            }
            guard let payload else {
                // 单张图拿不到:跳过,不毒化整库(渲染端会保留远程 src /
                // 显示占位),但记下来让调用方知道缺了哪些。
                outcome.skippedImageURLs.append(url)
                continue
            }
            let id = Self.imageID(url)
            context.insert(BankImage(id: id, remoteURL: url,
                                     mimeType: payload.mimeType, data: payload.data))
            version.imageCount += 1
            outcome.imageCount += 1
        }
        try context.save()
        imageResolver.invalidate()
        return outcome
    }

    /// 单张下载:任何失败(URL 不合法、超时、非 2xx、字节非图片)都返回 nil,
    /// 由调用方记进 skipped —— 一张坏图不该让整个题库构建作废。
    private static func downloadImage(_ url: String) async -> (data: Data, mimeType: String)? {
        guard let remote = URL(string: url) else { return nil }
        // 只收真正的图片:非 2xx(如 400)或内容非图片(实体转义 URL 的
        // 错误体)一律不入库——否则 localize 会把这些字节当 data URI,
        // 渲染出破图。
        guard let (data, response) = try? await URLSession.shared.data(from: remote),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              isImage(data: data, mimeType: http.mimeType) else { return nil }
        return (data, http.mimeType ?? "image/png")
    }

    /// 从题库包抽取(字节已过 CRC32 / sha256 / 长度校验,这里再过一道魔数)。
    private static func packageImage(
        _ url: String, package: BankPackage, index: [String: BankPackageImageEntry]
    ) -> (data: Data, mimeType: String)? {
        guard let entry = index[url],
              let data = try? package.extract("images/" + entry.file),
              looksLikeImage(data) else { return nil }
        return (data, entry.mime)
    }

    @MainActor
    func appendLog(_ entry: PracticeUpstreamClient.CrawlLogEntry) throws {
        let context = ModelContext(container)
        context.insert(BankCrawlLogRecord(entry: entry))
        try context.save()
    }

    /// Drops the whole SwiftData mirror (我的 > 删除题库 and the UI-test
    /// -reset-bank hook). The JSONL files are cleared by AppState — without
    /// this the DB keeps a current version and ensureBankReady would serve the
    /// old bank instead of re-crawling.
    @MainActor
    func resetAll() throws {
        let context = ModelContext(container)
        try context.delete(model: BankVersion.self)
        try context.delete(model: BankCrawlLogRecord.self)
        try context.delete(model: BankOptionRecord.self)
        try context.delete(model: BankQuestionRecord.self)
        try context.delete(model: BankImage.self)
        try context.save()
        imageResolver.invalidate()
    }

    /// Extract every image URL an <img> tag references. `src` takes
    /// precedence, `data-src` is only the lazy-load fallback, and the value is
    /// HTML-entity-unescaped so raw (`&latex=`) and escaped
    /// (`&amp;latex=`) serializations collapse to ONE canonical key. (The old
    /// greedy `<img[^>]*(?:src|data-src)=` regex captured the LAST attribute —
    /// usually the protocol-relative, entity-escaped data-src — so the same
    /// formula image got stored under two keys, and the escaped form's
    /// download 400s because `&amp;` is sent to the server verbatim.)
    nonisolated static func imageURLs(from html: String) -> [String] {
        guard let imgRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let tag = ns.substring(with: match.range)
            guard let value = attributeValue(named: "src", in: tag) ?? attributeValue(named: "data-src", in: tag) else { return nil }
            let decoded = value
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            return decoded.hasPrefix("//") ? "https:\(decoded)" : decoded
        }
    }

    /// First occurrence of `name="…"` inside a tag. The `(?<!-)` lookbehind
    /// excludes `data-src` when looking for `src`.
    nonisolated private static func attributeValue(named name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!-)\b\#(name)\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func imageID(_ url: String) -> String {
        Hashing.sha256Hex(url)
    }

    /// Checks the first bytes of a downloaded payload: PNG / JPEG / GIF /
    /// WebP — the formats every component (formulas, charts, photos) uses.
    /// The `image/*` mime type alone is not enough: the upstream may answer
    /// 200 with a JSON error body.
    nonisolated static func isImage(data: Data, mimeType: String?) -> Bool {
        // 非 image/* 的 content-type(如 application/problem+json)直接否掉。
        guard let mimeType, mimeType.hasPrefix("image/") else { return false }
        // content-type 声称是图片仍要过一道魔数,CDN 偶发以 image/png 返回
        // 错误体。魔数检查自带长度语义,不再前置最小长度。
        return looksLikeImage(data)
    }

    /// 只看字节魔数:PNG / JPEG / GIF / WebP —— 各组件(公式、图表、照片)
    /// 实际使用的格式。用于 content-type 不可信、或手上只有字节的场景
    /// (题库包里的图、库里的既有记录)。
    nonisolated static func looksLikeImage(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }  // PNG
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }        // JPEG
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }  // GIF8
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),                 // RIFF…WEBP
           data[8 ..< 12].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return true }
        return false
    }
}

@MainActor
final class BankImageResolver: @unchecked Sendable {
    private let container: ModelContainer
    private var context: ModelContext?
    /// 本地化结果按 URL 缓存。data URI 体积是大头(单张最大 200 KB+),
    /// 所以只留少量,不按库规模常驻。
    private let uriCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 24
        return cache
    }()
    private let decodedCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        // 位图按字节封顶(946×885 的图表解码后约 3.3 MB),只限张数会爆内存。
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    init(container: ModelContainer) { self.container = container }

    /// 只重写「本块里真正出现的图」。旧实现按全库 7500+ 个键逐个
    /// replacingOccurrences,且替换后字符串被 base64 撑大后还要被后续每一次
    /// 扫描 —— 75 题实测 24 秒,纯文本块也要付全价。现在降到 O(本块图片数),
    /// 无图块直接原样返回。
    func localize(_ html: String) -> String {
        let urls = Set(BankDatabase.imageURLs(from: html))
        guard !urls.isEmpty else { return html }
        var result = html
        for url in urls {
            guard let uri = dataURI(for: url) else { continue }
            result = result.replacingOccurrences(of: url, with: uri)
            // 上游同一张图有 raw(&latex=) 与实体转义(&amp;latex=) 两种序列化。
            let escaped = url.replacingOccurrences(of: "&", with: "&amp;")
            if escaped != url { result = result.replacingOccurrences(of: escaped, with: uri) }
        }
        return result
    }

    /// 原始图 URL → 解码后的 UIImage(原生图片块直接渲染,不进 WebView)。
    /// 解码结果按字节计费缓存;换题库后 invalidate 一并清空。
    func image(for remoteURL: String) -> UIImage? {
        let raw = Self.canonical(remoteURL)
        if let cached = decodedCache.object(forKey: raw as NSString) { return cached }
        guard let entry = imageData(for: raw) else { return nil }
        guard let image = UIImage(data: entry.data) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        decodedCache.setObject(image, forKey: raw as NSString, cost: cost)
        return image
    }

    /// 换题库(重爬)或删除题库后清空:上下文要丢掉,否则旧库的行会被缓存住。
    func invalidate() {
        uriCache.removeAllObjects()
        decodedCache.removeAllObjects()
        context = nil
    }

    /// 上游对同一张图有 raw / 实体转义两种写法,统一到 raw 形式作键。
    private static func canonical(_ url: String) -> String {
        url.replacingOccurrences(of: "&amp;", with: "&")
    }

    private func dataURI(for remoteURL: String) -> String? {
        let raw = Self.canonical(remoteURL)
        if let cached = uriCache.object(forKey: raw as NSString) { return cached as String }
        guard let entry = imageData(for: raw) else { return nil }
        let uri = "data:\(entry.mimeType);base64,\(entry.data.base64EncodedString())"
        uriCache.setObject(uri as NSString, forKey: raw as NSString)
        return uri
    }

    /// 按需取单张(不再全表 materialize + base64 常驻 —— 那让 4335 张图变成
    /// 180 MB 常驻内存,且首次调用同步发生在主线程)。命中多条时取第一条
    /// 字节真是图片的:旧库存在同图双键(legacy raw + &amp;)以及 400-JSON
    /// 错误体记录,不能把非图片字节交给渲染端。
    private func imageData(for raw: String) -> (data: Data, mimeType: String)? {
        let escaped = raw.replacingOccurrences(of: "&", with: "&amp;")
        let context = cachedContext()
        var descriptor = FetchDescriptor<BankImage>(
            predicate: #Predicate { $0.remoteURL == raw || $0.remoteURL == escaped }
        )
        descriptor.fetchLimit = 8
        guard let records = try? context.fetch(descriptor) else { return nil }
        for record in records where BankDatabase.isImage(data: record.data, mimeType: record.mimeType) {
            return (record.data, record.mimeType)
        }
        return nil
    }

    private func cachedContext() -> ModelContext {
        if let context { return context }
        let context = ModelContext(container)
        self.context = context
        return context
    }
}
