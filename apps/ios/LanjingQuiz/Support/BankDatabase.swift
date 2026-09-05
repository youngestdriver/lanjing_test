import Foundation
import SwiftData

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
        let context = ModelContext(container)
        guard let images = try? context.fetch(FetchDescriptor<BankImage>()), !images.isEmpty else { return html }
        var result = html
        for image in images where !image.remoteURL.isEmpty {
            result = result.replacingOccurrences(of: image.remoteURL, with: "lanjing-image://\(image.id)")
        }
        return result
    }

    @MainActor
    func replaceCurrent(with groups: [String: [BankQuestion]], papers: [String: Bool] = [:]) async throws {
        let context = ModelContext(container)
        let old = try context.fetch(FetchDescriptor<BankVersion>())
        for version in old { context.delete(version) }
        // 旧题记录/题图与 BankVersion 无关联,不会随版本行级联删除:必须显式
        // 清掉,否则每次 更新题库 都残留一批孤儿记录,且 BankImage 的确定性
        // 主键(URL 的 sha256)会在 @Attribute(.unique) 上重插冲突。
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
        for url in urls {
            guard let remote = URL(string: url),
                  let (data, response) = try? await URLSession.shared.data(from: remote),
                  !data.isEmpty else { continue }
            let id = Self.imageID(url)
            let mime = (response as? HTTPURLResponse)?.mimeType ?? "image/png"
            context.insert(BankImage(id: id, remoteURL: url, mimeType: mime, data: data))
            version.imageCount += 1
        }
        try context.save()
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
    }

    private static func imageURLs(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*(?:src|data-src)=["']([^"']+)["'][^>]*>"#, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard $0.numberOfRanges > 1 else { return nil }
            let value = ns.substring(with: $0.range(at: 1))
            return value.hasPrefix("//") ? "https:\(value)" : value
        }
    }

    private static func imageID(_ url: String) -> String {
        Hashing.sha256Hex(url)
    }
}
