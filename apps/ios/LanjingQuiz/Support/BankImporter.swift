import Foundation

/// 「导入题库」:把一个自描述的题库包(zip,格式定义见 apps/bank/lib/snapshot.js)
/// 装进本地库,**全程零网络** —— 这是让练习/测试不受上游可达性影响的那条路。
///
/// 顺序上刻意「先把包校验完、再动本地库」:中央目录、manifest 与包内条目的
/// 对齐、每条图的 CRC32/sha256/长度、题目逐行解码与计数自洽,全部在
/// `BankPackage` 里先跑完 —— 任何一步失败时本地库一个字节都没动,不会留下
/// 半个残库。
///
/// 真正写库时是**先删后插**:SwiftData 的 @Attribute(.unique) 主键重复插入
/// 是就地 upsert 而不是报错(见 testUniqueIDConflictUpsertsInsteadOfThrowing),
/// 先插会把旧版本的记录静默改写成新版,「失败时旧库保持完整」随之失效。
@MainActor
enum BankImporter {

    /// 导入结果。`skippedImageURLs` 是题目引用了、但包里没有的题图 —— 正常包
    /// 应当为空,非空说明包与题目数据不同步,必须如实告诉用户而不是吞掉
    /// (静默丢弃正是「有的图永远显示不出来」的根因之一)。
    struct Summary: Equatable {
        let questionCount: Int
        let imageCount: Int
        let byCategory: [String: Int]
        let skippedImageURLs: [String]

        var message: String {
            var text = "已导入 \(questionCount) 题、\(imageCount) 张图"
            if !skippedImageURLs.isEmpty {
                text += "；另有 \(skippedImageURLs.count) 张题图不在包内，相关题目会显示图片占位"
            }
            return text
        }
    }

    /// 打开并校验题库包。抽出来单独暴露,便于调试与测试先验包再导入。
    static func open(packageAt url: URL) throws -> BankPackage {
        try BankPackage(url: url)
    }

    /// 整体替换本地题库:JSONL 镜像与 SwiftData 库一起更新,与爬取路径
    /// (`BankDatabase.replaceCurrent`) 保持同一份数据,否则下次增量爬取的
    /// 去重依据会和库对不上。
    static func run(
        packageAt url: URL,
        database: BankDatabase,
        storage: BankStorage
    ) async throws -> Summary {
        // 1. 打开 + 校验包结构(含 manifest↔zip 双向对齐、条目名安全)
        let package = try open(packageAt: url)
        // 2. 题目逐行解码 + 计数自洽(坏一行就失败,不导入残库)
        let questions = try package.questions()
        let payloads = try package.questionPayloads()
        let counts = questions.mapValues(\.count)

        // 3. JSONL 镜像先落盘。meta.papers 留空:导入的库没有「哪些试卷已爬过」
        //    的概念,而 我的 > 更新题库 走的是 refresh(全量重爬),不读它。
        let meta = BankMeta(
            version: 1,
            round: 0,
            lastRun: ISO8601DateFormatter().string(from: .now),
            targets: BankLogic.categories,
            counts: counts,
            papers: [:]
        )
        try storage.saveAll(
            files: payloads.map { ($0.category, String(decoding: $0.data, as: UTF8.self)) },
            meta: meta
        )

        // 4. 写库(先删后插 + resolver 失效),图片从包里抽,零网络。
        let outcome = try await database.replaceCurrent(
            with: questions, papers: [:], imageSource: .package(package)
        )
        return Summary(
            questionCount: counts.values.reduce(0, +),
            imageCount: outcome.imageCount,
            byCategory: counts,
            skippedImageURLs: outcome.skippedImageURLs
        )
    }
}
