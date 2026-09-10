import XCTest
import SwiftData
@testable import LanjingQuiz

final class BankModelTests: XCTestCase {

    private func makeQuestion(
        answer: BankQuestion.Answer? = BankQuestion.Answer(letters: ["A"]),
        question: String = "<p>题干</p>",
        options: [String] = ["<p>A选项</p>", "<p>B选项</p>", "<p>C选项</p>", "<p>D选项</p>"],
        analysis: String? = "<p>解析</p>"
    ) -> BankQuestion {
        BankQuestion(
            id: "b1",
            category: "言语理解",
            section: "逻辑填空",
            subCategory: "成语辨析",
            question: question,
            stem: nil,
            options: options,
            answer: answer,
            analysis: analysis,
            sourceExamName: "【言语理解（二）】机考题库",
            round: nil,
            collectedAt: nil
        )
    }

    func testAnswerMapping() {
        // single letter
        let single = makeQuestion(answer: .init(letters: ["A"]))
        XCTAssertEqual(single.answer?.letters, ["A"])
        XCTAssertEqual(single.keys, [true, false, false, false])
        XCTAssertEqual(single.correctAnswers, ["A"])
        XCTAssertFalse(single.isMulti)
        XCTAssertTrue(single.isGradable)

        // multi letters
        let multi = makeQuestion(answer: .init(letters: ["B", "D"]))
        XCTAssertEqual(multi.keys, [false, true, false, true])
        XCTAssertTrue(multi.isMulti)
        XCTAssertEqual(multi.correctAnswers, ["B", "D"])

        // nil answer → ungradable, all keys false
        let none = makeQuestion(answer: nil)
        XCTAssertNil(none.answer)
        XCTAssertEqual(none.keys, [false, false, false, false])
        XCTAssertFalse(none.isGradable)
    }

    func testPreservesEmptyOptionSlots() {
        let question = makeQuestion(options: ["<p>A</p>", "", "", "<p>D</p>"])
        XCTAssertEqual(question.options, ["<p>A</p>", "", "", "<p>D</p>"])
        XCTAssertEqual(question.letters, ["A", "B", "C", "D"]) // slots preserved for answer alignment
    }

    func testNormalizesProtocolRelativeImgSrcs() {
        let question = makeQuestion(
            question: "<p>公式<img src=\"//fb.fbstatic.cn/1.png\">和<img src='//x.cn/2.png'></p>"
        )
        XCTAssertEqual(question.question, "<p>公式<img src=\"https://fb.fbstatic.cn/1.png\">和<img src='https://x.cn/2.png'></p>")
    }

    func testLeavesAbsoluteImgSrcsUntouched() {
        let html = "<p><img src=\"https://fb.fbstatic.cn/1.png\">已<url>正常</p>"
        let question = makeQuestion(question: html)
        XCTAssertEqual(question.question, html)
    }

    func testNormalizesAnalysisImagesToo() {
        let question = makeQuestion(analysis: "<p><img src='//x.cn/a.png'></p>")
        XCTAssertEqual(question.analysis, "<p><img src='https://x.cn/a.png'></p>")
    }

    // MARK: - JSONL persistence (crawl → store → read back)

    private func roundTrip(_ question: BankQuestion) throws -> BankQuestion {
        let encoder = JSONEncoder()
        let data = try encoder.encode(question)
        return try JSONDecoder().decode(BankQuestion.self, from: data)
    }

    func testEncodeDecodeRoundTripPreservesFields() throws {
        let original = makeQuestion()
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "b1")
        XCTAssertEqual(decoded.category, "言语理解")
        XCTAssertEqual(decoded.section, "逻辑填空")
        XCTAssertEqual(decoded.subCategory, "成语辨析")
        XCTAssertEqual(decoded.answer?.letters, ["A"])
        XCTAssertEqual(decoded.sourceExamName, "【言语理解（二）】机考题库")
        XCTAssertNil(decoded.round) // crawled records have no collector metadata
    }

    func testEncodeAnswerSingleLetterAsStringMultiAsArray() throws {
        let encoder = JSONEncoder()
        // single → "A" (collector-compatible string form)
        let single = try encoder.encode(makeQuestion(answer: .init(letters: ["A"])))
        XCTAssertTrue(String(data: single, encoding: .utf8)!.contains("\"answer\":\"A\""))
        // multi → ["A","C"]
        let multi = try encoder.encode(makeQuestion(answer: .init(letters: ["A", "C"])))
        XCTAssertTrue(String(data: multi, encoding: .utf8)!.contains("\"answer\":[\"A\",\"C\"]"))
        // nil → key omitted (synthesized encodeIfPresent); decoding tolerates
        // both omission and the collector's explicit "answer":null.
        let none = try encoder.encode(makeQuestion(answer: nil))
        let noneJSON = String(data: none, encoding: .utf8)!
        XCTAssertFalse(noneJSON.contains("\"answer\""))
        XCTAssertNoThrow(try JSONDecoder().decode(BankQuestion.self, from: none))
    }

    func testDecodesCollectorFormatLine() throws {
        // A hand-written line in apps/bank/data format (round/collectedAt
        // present, answer as array).
        let line = """
        {"_id":"q9","category":"言语理解","section":"逻辑填空","subCategory":"成语辨析",\
        "question":"<p>题干</p>","options":["<p>A</p>","","",""],\
        "answer":["A","C"],"analysis":"<p>解析</p>","sourceExamName":"【言语理解（二）】机考题库",\
        "round":4,"collectedAt":"2026-08-07T00:00:00.000Z"}
        """
        let question = try JSONDecoder().decode(BankQuestion.self, from: Data(line.utf8))
        XCTAssertEqual(question.id, "q9")
        XCTAssertEqual(question.options, ["<p>A</p>", "", "", ""])
        XCTAssertEqual(question.answer?.letters, ["A", "C"])
        XCTAssertTrue(question.isMulti)
        XCTAssertEqual(question.round, 4)
        // records crawled before stems were stored have no stem key
        XCTAssertNil(question.stem)
    }

    /// Upstream serializes formula img hrefs in BOTH raw (`&latex=`) and
    /// entity-escaped (`&amp;latex=`) forms, and often carries the escaped
    /// `data-src` alongside. imageURLs must normalize every form to one
    /// canonical key; otherwise BankImage stores a duplicate entry whose
    /// download returns 400 (its &amp; is sent verbatim to the server) and the
    /// HTML src that renders stays unlocalized → broken formula icons.
    func testImageURLsCanonicalizesRawAndEscapedForms() {
        let raw = "https://fb.fbstatic.cn/api/planet/accessories/formulas?fontSize=18&latex=abc"
        let escaped = "https://fb.fbstatic.cn/api/planet/accessories/formulas?fontSize=18&amp;latex=abc"
        // src first, raw — the common upstream shape.
        XCTAssertEqual(
            BankDatabase.imageURLs(from: "<img flag=\"tex\" src=\"\(raw)\" data-src=\"\(escaped)\">"),
            [raw]
        )
        // src itself serialized as &amp; (some papers).
        XCTAssertEqual(
            BankDatabase.imageURLs(from: "<img flag=\"tex\" src=\"\(escaped)\">"),
            [raw]
        )
        // Only data-src, protocol-relative — the lazy-load shape.
        XCTAssertEqual(
            BankDatabase.imageURLs(from: "<img flag=\"tex\" data-src=\"//fb.fbstatic.cn/api/planet/accessories/formulas?fontSize=18&amp;latex=abc\">"),
            [raw]
        )
        // src AFTER data-src — the old greedy regex took the wrong attribute.
        XCTAssertEqual(
            BankDatabase.imageURLs(from: "<img flag=\"tex\" data-src=\"//fb.fbstatic.cn/api/planet/accessories/formulas?fontSize=18&amp;latex=abc\" src=\"\(raw)\">"),
            [raw]
        )
        XCTAssertEqual(BankDatabase.imageURLs(from: "<p>no images</p>"), [])
    }

    /// Legacy banks store the same formula under TWO keys (raw `&` and
    /// entity-escaped `&amp;`), and the old crawler even saved 400-JSON error
    /// bodies for the escaped ones. The resolver must merge the duplicate
    /// keys without crashing (uniqueKeysWithValues traps on them) and never
    /// hand a non-image payload to the renderer.
    @MainActor
    func testImageResolverToleratesLegacyDuplicateKeys() throws {
        let database = try BankDatabase(inMemory: true)
        let context = ModelContext(database.container)
        let rawURL = "https://fb.fbstatic.cn/api/planet/accessories/formulas?fontSize=18&latex=abc"
        let ampURL = rawURL.replacingOccurrences(of: "&", with: "&amp;")
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let jsonGarbage = Data("{\"title\":\"Bad Request\"}".utf8)
        context.insert(BankImage(id: "raw", remoteURL: rawURL, data: Data(png)))
        context.insert(BankImage(id: "amp", remoteURL: ampURL, data: jsonGarbage))
        try context.save()

        let resolver = BankImageResolver(container: database.container)
        let result = resolver.localize("<img src=\"\(rawURL)\" data-src=\"\(ampURL)\">")
        XCTAssertTrue(result.contains("data:image/png"), "both forms must resolve to a data URI")
        XCTAssertFalse(result.contains(rawURL), "raw src must be localized")
        XCTAssertFalse(result.contains(ampURL), "escaped form must be localized too")
    }

    /// localize 只应触碰「本块里出现过的图」:纯文本块必须原样返回(全库
    /// 逐键扫描正是 75 题 24 秒的根因),块内未入库的图保留远程 src。
    @MainActor
    func testLocalizeOnlyTouchesImagesPresentInThisBlock() throws {
        let database = try BankDatabase(inMemory: true)
        let context = ModelContext(database.container)
        let stored = "https://test.lanjingweike.com/oss/chart.png"
        let unknown = "https://test.lanjingweike.com/oss/not-downloaded.png"
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        context.insert(BankImage(id: "chart", remoteURL: stored, data: png))
        try context.save()

        let resolver = BankImageResolver(container: database.container)
        // 纯文本:原样返回,不做任何替换
        XCTAssertEqual(resolver.localize("<p>没有图的题干</p>"), "<p>没有图的题干</p>")
        // 未入库的图:保留远程 src(渲染端据此降级),不得改写成空/坏值
        XCTAssertEqual(resolver.localize("<img src=\"\(unknown)\">"), "<img src=\"\(unknown)\">")
        // 入库的图:本块内替换为 data URI
        let localized = resolver.localize("<p>材料</p><p><img src=\"\(stored)\"></p>")
        XCTAssertTrue(localized.contains("data:image/png;base64,"))
        XCTAssertFalse(localized.contains(stored))
        XCTAssertTrue(localized.contains("<p>材料</p>"), "无图段落不得被改写")
    }

    /// SwiftData 对 @Attribute(.unique) 主键重复插入的真实行为:**不抛错,
    /// 就地改写**(实测 rows 仍为 1、旧行值被新值覆盖)。
    ///
    /// 这条契约决定导入/重爬的写入顺序:绝不能"先插入新行再切换 current"
    /// —— 主键重合时新行会静默改写旧版本记录(例如把 BankQuestionRecord.
    /// versionID 改掉),「失败时旧库保持完整」随之失效。必须先删后插,
    /// 或把导入写进独立的 store 文件再整体替换。仓内 replaceCurrent 注释
    /// 原先断言"重插会触发 unique 冲突",已被本用例证伪。
    @MainActor
    func testUniqueIDConflictUpsertsInsteadOfThrowing() throws {
        let database = try BankDatabase(inMemory: true)
        let context = ModelContext(database.container)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        context.insert(BankImage(id: "same", remoteURL: "https://a.cn/1.png", data: png))
        try context.save()

        context.insert(BankImage(id: "same", remoteURL: "https://a.cn/2.png", data: png))
        XCTAssertNoThrow(try context.save(), "重复 unique 主键不抛错")

        let rows = try context.fetch(FetchDescriptor<BankImage>())
        XCTAssertEqual(rows.count, 1, "重复 id 不产生新行 —— 是就地 upsert")
        XCTAssertEqual(rows.first?.remoteURL, "https://a.cn/2.png", "旧行被新值静默覆盖")
    }

    /// native 图块按 remote URL 直出解码位图;data URI 不是键,查不到属正常。
    @MainActor
    func testResolverServesDecodedImageByRemoteURL() throws {
        let database = try BankDatabase(inMemory: true)
        let context = ModelContext(database.container)
        let url = "https://test.lanjingweike.com/oss/chart.png"
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        context.insert(BankImage(id: "chart", remoteURL: url, data: png))
        try context.save()

        let resolver = BankImageResolver(container: database.container)
        XCTAssertNotNil(resolver.image(for: url))
        XCTAssertNil(resolver.image(for: "https://test.lanjingweike.com/oss/absent.png"))
        XCTAssertNil(resolver.image(for: "data:image/png;base64,AAAA"),
                     "data URI 不是 remote 键 —— 这正是灰条回归的形态")
    }

    func testDecodesCombRecordWithStem() throws {
        let line = """
        {"_id":"c1","category":"资料分析","section":"文字资料","subCategory":"其他",\
        "question":"<p>小题</p>","stem":"<p>共享材料</p>","options":["<p>A</p>","","",""],\
        "answer":"A","analysis":"","sourceExamName":"【资料分析（一）】机考题库",\
        "round":1,"collectedAt":"2026-08-07T00:00:00.000Z"}
        """
        let question = try JSONDecoder().decode(BankQuestion.self, from: Data(line.utf8))
        XCTAssertEqual(question.stem, "<p>共享材料</p>")
        // round-trip preserves the stem
        let roundTripped = try roundTrip(question)
        XCTAssertEqual(roundTripped.stem, "<p>共享材料</p>")
    }
}
