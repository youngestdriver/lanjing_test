import CryptoKit
import XCTest
@testable import LanjingQuiz

/// 题库包读取层的测试。夹具用的是本文件自己写的 zip writer(仅 STORED)——
/// 「读」与「写」保持两份独立实现,写坏了还能读出来才算真发现问题,也免去对
/// node / 外部打包脚本的依赖。
final class BankPackageTests: XCTestCase {

    // MARK: - 成功路径

    func testOpensPackageAndExposesManifest() throws {
        let fixture = try writePackage()
        let package = try BankPackage(url: fixture.url)

        XCTAssertEqual(package.url, fixture.url)
        XCTAssertEqual(package.manifest.formatVersion, 1)
        XCTAssertEqual(package.manifest.generatedAt, "2026-09-10T00:00:00.000Z")
        XCTAssertEqual(package.manifest.counts.questions, 3)
        XCTAssertEqual(package.manifest.counts.images, 2)
        XCTAssertEqual(package.manifest.counts.byCategory, ["言语理解": 2, "数字运算": 1])
        XCTAssertEqual(Set(package.questionFiles), ["questions/言语理解.jsonl", "questions/数字运算.jsonl"])
        XCTAssertEqual(Set(package.imageEntries.map(\.file)), ["a1b2.png", "c3d4.png"])
        // 1 manifest + 2 分类 + 2 图
        XCTAssertEqual(package.entries.count, 5)
    }

    func testExtractReturnsVerifiedBytes() throws {
        let fixture = try writePackage()
        let package = try BankPackage(url: fixture.url)

        let image = try XCTUnwrap(package.imageEntries.first { $0.file == "a1b2.png" })
        // 中文分类名的条目名走 zip 通用位 11(UTF-8),解不出来这里就会是乱码/找不到。
        XCTAssertEqual(try package.extract("questions/言语理解.jsonl"), fixture.questionData["言语理解"])
        XCTAssertEqual(try package.extract("manifest.json"), fixture.manifestData)
        XCTAssertEqual(try package.extractImage(image), fixture.imageData["a1b2.png"])
    }

    func testQuestionPayloadsCarryCategoryFromEntryName() throws {
        let fixture = try writePackage()
        let package = try BankPackage(url: fixture.url)

        let payloads = try package.questionPayloads()
        XCTAssertEqual(payloads.map(\.category), ["数字运算", "言语理解"])
        XCTAssertEqual(payloads.first { $0.category == "数字运算" }?.data, fixture.questionData["数字运算"])
    }

    func testQuestionsDecodeByCategory() throws {
        let fixture = try writePackage()
        let package = try BankPackage(url: fixture.url)

        let questions = try package.questions()
        XCTAssertEqual(questions.keys.sorted(), ["数字运算", "言语理解"])
        XCTAssertEqual(questions["言语理解"]?.count, 2)
        XCTAssertEqual(questions["数字运算"]?.count, 1)

        let first = try XCTUnwrap(questions["言语理解"]?.first)
        XCTAssertEqual(first.id, "q1")
        XCTAssertEqual(first.category, "言语理解")
        XCTAssertEqual(first.section, "逻辑填空")
        XCTAssertEqual(first.subCategory, "成语辨析")
        XCTAssertEqual(first.answer?.letters, ["A"])
        XCTAssertEqual(first.options.count, 4)
        XCTAssertEqual(first.sourceExamName, "【言语理解（二）】机考题库")
    }

    // MARK: - 不是 zip / 结构损坏

    func testRejectsFileThatIsNotAZip() throws {
        let url = try writeTempFile(Data(repeating: 0x41, count: 4096))
        assertThrows(.notAZip("\(url.lastPathComponent) 找不到 EOCD(不是 zip,或已损坏)")) { try BankPackage(url: url) }
    }

    func testRejectsFileTooSmallForZip() throws {
        let url = try writeTempFile(Data("不是 zip".utf8))
        XCTAssertThrowsError(try BankPackage(url: url)) { error in
            guard let packageError = error as? BankPackageError, case .notAZip(let detail) = packageError else {
                return XCTFail("期望 notAZip,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("放不下 zip 的最小结构"), detail)
        }
    }

    func testRejectsMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BankPackageTests-absent-\(UUID().uuidString).zip")
        XCTAssertThrowsError(try BankPackage(url: url)) { error in
            guard let packageError = error as? BankPackageError, case .notAZip = packageError else {
                return XCTFail("期望 notAZip,实际 \(error)")
            }
        }
    }

    func testRejectsCorruptCentralDirectoryEntryCount() throws {
        // EOCD 说 6 条,中央目录里只有 5 条:多出来的那一条越界。
        let fixture = try writePackage(eocdEntryCount: 6)
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .corruptCentralDirectory(let detail) = packageError else {
                return XCTFail("期望 corruptCentralDirectory,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("越界"), detail)
        }
    }

    func testRejectsCompressedEntry() throws {
        // method=99(压缩条目):本格式要求全 STORED,不能靠猜去 inflate。
        let fixture = try writePackage(extraEntries: [
            StoredZipWriter.Entry(name: "images/compressed.png", data: Data(repeating: 0x11, count: 64), method: 99),
        ])
        assertThrows(.unsupportedCompressionMethod(entry: "images/compressed.png", method: 99)) { try BankPackage(url: fixture.url) }
    }

    func testRejectsZip64Sentinel() throws {
        let fixture = try writePackage(zip64Sentinel: true)
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .zip64Unsupported = packageError else {
                return XCTFail("期望 zip64Unsupported,实际 \(error)")
            }
        }
    }

    func testRejectsPathTraversalEntryName() throws {
        let traversal = try writePackage(extraEntries: [
            StoredZipWriter.Entry(name: "images/../evil.png", data: Data(repeating: 0x22, count: 16)),
        ])
        assertThrows(.unsafeEntryName("images/../evil.png")) { try BankPackage(url: traversal.url) }

        let absolute = try writePackage(extraEntries: [
            StoredZipWriter.Entry(name: "/etc/passwd", data: Data(repeating: 0x33, count: 16)),
        ])
        assertThrows(.unsafeEntryName("/etc/passwd")) { try BankPackage(url: absolute.url) }
    }

    // MARK: - manifest 本身有问题

    func testRejectsMissingManifest() throws {
        let fixture = try writePackage(includeManifest: false)
        assertThrows(.missingManifest) { try BankPackage(url: fixture.url) }
    }

    func testRejectsUnsupportedFormatVersion() throws {
        let fixture = try writePackage(formatVersion: 99)
        assertThrows(.unsupportedFormatVersion(99)) { try BankPackage(url: fixture.url) }
    }

    func testRejectsManifestThatIsNotJSON() throws {
        let fixture = try writePackage(includeManifest: false, extraEntries: [
            StoredZipWriter.Entry(name: "manifest.json", data: Data("{不是 JSON".utf8)),
        ])
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .malformedManifest = packageError else {
                return XCTFail("期望 malformedManifest,实际 \(error)")
            }
        }
    }

    func testRejectsManifestMissingRequiredField() throws {
        // counts 里少了 images 字段:解码失败也算 manifest 不可用,不能带着半份清单往下走。
        let fixture = try writePackage(includeManifest: false, extraEntries: [
            StoredZipWriter.Entry(name: "manifest.json", data: Data(#"{"formatVersion":1,"generatedAt":"x"}"#.utf8)),
        ])
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .malformedManifest = packageError else {
                return XCTFail("期望 malformedManifest,实际 \(error)")
            }
        }
    }

    // MARK: - manifest 与包内容不一致

    func testRejectsManifestDeclaringMissingQuestionFile() throws {
        let fixture = try writePackage { manifest in
            var counts = manifest["counts"] as? [String: Any] ?? [:]
            var byCategory = counts["byCategory"] as? [String: Int] ?? [:]
            byCategory["判断推理"] = 5
            counts["byCategory"] = byCategory
            counts["questions"] = 8
            manifest["counts"] = counts
        }
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("questions/判断推理.jsonl"), detail)
        }
    }

    func testRejectsUndeclaredQuestionFileInZip() throws {
        let fixture = try writePackage(extraEntries: [
            StoredZipWriter.Entry(name: "questions/判断推理.jsonl", data: Data("{}".utf8)),
        ])
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("判断推理"), detail)
        }
    }

    func testRejectsStrayFileUnderQuestionsDirectory() throws {
        // questions/ 下只允许 manifest 声明过的 <分类>.jsonl,别的一律算清单外多余文件。
        let fixture = try writePackage(extraEntries: [
            StoredZipWriter.Entry(name: "questions/README.txt", data: Data("说明".utf8)),
        ])
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("questions/README.txt"), detail)
        }
    }

    func testRejectsManifestDeclaringMissingImage() throws {
        let fixture = try writePackage { manifest in
            var images = manifest["images"] as? [[String: Any]] ?? []
            images.append(["url": "https://example.test/ghost.png", "file": "ghost.png",
                           "mime": "image/png", "bytes": 3, "sha256": String(repeating: "0", count: 64)])
            manifest["images"] = images
            var counts = manifest["counts"] as? [String: Any] ?? [:]
            counts["images"] = images.count
            manifest["counts"] = counts
        }
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("images/ghost.png"), detail)
        }
    }

    func testRejectsUndeclaredImageInZip() throws {
        let fixture = try writePackage(extraEntries: [
            StoredZipWriter.Entry(name: "images/ghost.png", data: Data(repeating: 0x44, count: 16)),
        ])
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("images/ghost.png"), detail)
        }
    }

    func testRejectsCountsThatContradictThemselves() throws {
        // counts.questions 说 5 题,byCategory 加起来只有 3 —— 打开就该拒绝。
        let fixture = try writePackage { manifest in
            var counts = manifest["counts"] as? [String: Any] ?? [:]
            counts["questions"] = 5
            manifest["counts"] = counts
        }
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("byCategory"), detail)
        }
    }

    func testRejectsCountsImagesNotMatchingImageArray() throws {
        let fixture = try writePackage { manifest in
            var counts = manifest["counts"] as? [String: Any] ?? [:]
            counts["images"] = 7
            manifest["counts"] = counts
        }
        XCTAssertThrowsError(try BankPackage(url: fixture.url)) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("counts.images=7"), detail)
        }
    }

    func testRejectsQuestionCountMismatchWithJSONL() throws {
        // 文件都在,只是答应给的题数比 JSONL 实际的多 —— 打开时不报错,解码时挡。
        let fixture = try writePackage { manifest in
            var counts = manifest["counts"] as? [String: Any] ?? [:]
            var byCategory = counts["byCategory"] as? [String: Int] ?? [:]
            byCategory["言语理解"] = 3
            counts["byCategory"] = byCategory
            counts["questions"] = 4
            manifest["counts"] = counts
        }
        let package = try BankPackage(url: fixture.url)
        XCTAssertThrowsError(try package.questions()) { error in
            guard let packageError = error as? BankPackageError, case .manifestMismatch(let detail) = packageError else {
                return XCTFail("期望 manifestMismatch,实际 \(error)")
            }
            XCTAssertTrue(detail.contains("言语理解"), detail)
        }
    }

    // MARK: - 条目内容校验

    func testRejectsCRCMismatch() throws {
        let fixture = try writePackage(corruptCRCFor: "manifest.json")
        let expected = crc32(fixture.manifestData)
        assertThrows(.crcMismatch(entry: "manifest.json", expected: 0xDEAD_BEEF, actual: expected)) {
            try BankPackage(url: fixture.url)
        }
    }

    func testRejectsDeclaredByteCountMismatch() throws {
        let fixture = try writePackage { manifest in
            var images = manifest["images"] as? [[String: Any]] ?? []
            images[0]["bytes"] = 9999
            manifest["images"] = images
        }
        let package = try BankPackage(url: fixture.url)
        let image = try XCTUnwrap(package.imageEntries.first)
        let actual = try XCTUnwrap(fixture.imageData[image.file]).count
        assertThrows(.byteCountMismatch(entry: "images/\(image.file)", expected: 9999, actual: actual)) {
            try package.extractImage(image)
        }
    }

    func testRejectsSha256Mismatch() throws {
        let fixture = try writePackage { manifest in
            var images = manifest["images"] as? [[String: Any]] ?? []
            images[0]["sha256"] = String(repeating: "0", count: 64)
            manifest["images"] = images
        }
        let package = try BankPackage(url: fixture.url)
        let image = try XCTUnwrap(package.imageEntries.first)
        assertThrows(.sha256Mismatch(entry: "images/\(image.file)")) { try package.extractImage(image) }
    }

    func testRejectsUnknownEntryName() throws {
        let fixture = try writePackage()
        let package = try BankPackage(url: fixture.url)
        assertThrows(.missingEntry("images/nope.png")) { try package.extract("images/nope.png") }
    }

    // MARK: - JSONL 解码

    func testRejectsMalformedJSONLLineWithCategoryAndLineNumber() throws {
        let fixture = try writePackage(questionData: [
            // 第 1 行好、第 2 行坏、第 3 行好:行号必须指向坏的那行。
            "言语理解": jsonl([
                questionLine(id: "q1"),
                #"{"_id":"q2","category":"言语理解""#,
                questionLine(id: "q3"),
            ]),
        ])
        let package = try BankPackage(url: fixture.url)
        XCTAssertThrowsError(try package.questions()) { error in
            guard let packageError = error as? BankPackageError,
                  case .malformedJSONL(let category, let line, _) = packageError else {
                return XCTFail("期望 malformedJSONL,实际 \(error)")
            }
            XCTAssertEqual(category, "言语理解")
            XCTAssertEqual(line, 2)
        }
    }

    func testRejectsRecordWithoutOptions() throws {
        // BankQuestion.init(from:) 对坏 options 会静默降级成空数组,只数行数挡不住。
        let fixture = try writePackage(questionData: [
            "言语理解": jsonl([
                questionLine(id: "q1"),
                #"{"_id":"q2","category":"言语理解","question":"<p>没有选项</p>","answer":"A"}"#,
            ]),
        ])
        let package = try BankPackage(url: fixture.url)
        XCTAssertThrowsError(try package.questions()) { error in
            guard let packageError = error as? BankPackageError,
                  case .invalidQuestion(let category, let line, let reason) = packageError else {
                return XCTFail("期望 invalidQuestion,实际 \(error)")
            }
            XCTAssertEqual(category, "言语理解")
            XCTAssertEqual(line, 2)
            XCTAssertTrue(reason.contains("选项"), reason)
        }
    }

    func testRejectsRecordWithEmptyOptionsArray() throws {
        let fixture = try writePackage(questionData: [
            "言语理解": jsonl([questionLine(id: "q1", options: [])]),
        ])
        let package = try BankPackage(url: fixture.url)
        XCTAssertThrowsError(try package.questions()) { error in
            guard let packageError = error as? BankPackageError,
                  case .invalidQuestion(_, let line, _) = packageError else {
                return XCTFail("期望 invalidQuestion,实际 \(error)")
            }
            XCTAssertEqual(line, 1)
        }
    }

    func testRejectsRecordWithoutID() throws {
        let fixture = try writePackage(questionData: [
            "言语理解": jsonl([#"{"category":"言语理解","question":"<p>没有 _id</p>","options":["<p>A</p>"]}"#]),
        ])
        let package = try BankPackage(url: fixture.url)
        XCTAssertThrowsError(try package.questions()) { error in
            guard let packageError = error as? BankPackageError,
                  case .invalidQuestion(_, let line, let reason) = packageError else {
                return XCTFail("期望 invalidQuestion,实际 \(error)")
            }
            XCTAssertEqual(line, 1)
            XCTAssertTrue(reason.contains("_id"), reason)
        }
    }

    func testBlankLinesAreSkipped() throws {
        // 真实产物每个 jsonl 末尾都有一个换行 —— 空行只跳过、不占行号。
        let fixture = try writePackage(questionData: [
            "言语理解": Data("\n\(questionLine(id: "q1"))\n\n".utf8),
        ])
        let package = try BankPackage(url: fixture.url)
        let questions = try package.questions()
        XCTAssertEqual(questions["言语理解"]?.map(\.id), ["q1"])
    }

    // MARK: - 真实产物

    /// 真包验证:apps/bank/data/lanjing-bank-*.zip(snapshot.js 的产物)。产物不在
    /// (比如没跑过打包脚本)就跳过 —— 这条的价值全在「真包能过」,拿自造夹具冒充
    /// 没有意义。
    func testRealSnapshotPackageWhenPresent() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/apps/ios/LanjingQuizTests/BankPackageTests.swift
            .deletingLastPathComponent()                 // …/apps/ios/LanjingQuizTests
            .deletingLastPathComponent()                 // …/apps/ios
            .deletingLastPathComponent()                 // …/apps
            .deletingLastPathComponent()                 // 仓库根
        let dataDirectory = repoRoot.appendingPathComponent("apps/bank/data")
        let snapshot = (try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("lanjing-bank-") && $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
        guard let snapshot else {
            throw XCTSkip("apps/bank/data 下没有 lanjing-bank-*.zip,跳过真实产物验证")
        }

        let package = try BankPackage(url: snapshot)
        XCTAssertEqual(package.entries.count, 4341, "1 manifest + 5 分类 + 4335 图")
        XCTAssertEqual(package.questionFiles.count, 5)
        XCTAssertEqual(package.manifest.counts.questions, 3065)
        XCTAssertEqual(package.manifest.counts.images, 4335)
        XCTAssertEqual(package.imageEntries.count, 4335)
        XCTAssertEqual(package.manifest.counts.byCategory, [
            "言语理解": 500, "数字运算": 700, "逻辑推理": 700, "资料分析": 550, "特有题型": 615,
        ])
        // 中文分类名靠 zip 通用位 11(UTF-8)才解得出,顺带确认标志位确实置着。
        let questionEntry = try XCTUnwrap(package.entries.first { $0.name.hasPrefix("questions/") })
        XCTAssertNotEqual(questionEntry.flags & 0x0800, 0, "条目名带 UTF-8 标志位")
        XCTAssertEqual(Set(package.questionFiles), Set(package.manifest.counts.byCategory.keys.map { "questions/\($0).jsonl" }))

        let questions = try package.questions()
        XCTAssertEqual(questions.count, 5)
        XCTAssertEqual(questions.values.reduce(0) { $0 + $1.count }, 3065)
        XCTAssertEqual(questions["言语理解"]?.count, 500)
        let sample = try XCTUnwrap(questions["资料分析"]?.first)
        XCTAssertFalse(sample.id.isEmpty)
        XCTAssertFalse(sample.options.isEmpty, "真实产物里每题都得有选项")

        // 真抽一张图:CRC32 + manifest 声明的 bytes/sha256 全过,才可能拿到字节。
        let image = try XCTUnwrap(package.imageEntries.first)
        let bytes = try package.extractImage(image)
        XCTAssertEqual(bytes.count, image.bytes)
        XCTAssertTrue(isImageMagic(bytes), "题图字节应当是 PNG/JPEG/GIF 之一,实际 mime=\(image.mime)")
    }

    // MARK: - 夹具

    /// 一份写好盘的包 + 造它用到的原始部件(断言时逐字节比)。
    private struct Fixture {
        let url: URL
        let manifestData: Data
        let questionData: [String: Data]
        let imageData: [String: Data]
    }

    /// 写一份题库包到临时文件。默认参数就是一份结构完全正确的包;各条错误路径
    /// 靠覆盖参数造出来(`manifest` 变换、额外条目、故意写坏的 CRC 等)。
    private func writePackage(
        formatVersion: Int = BankPackage.supportedFormatVersion,
        questionData: [String: Data]? = nil,
        imageData: [String: Data]? = nil,
        includeManifest: Bool = true,
        includeImages: Bool = true,
        extraEntries: [StoredZipWriter.Entry] = [],
        corruptCRCFor: String? = nil,
        eocdEntryCount: Int? = nil,
        zip64Sentinel: Bool = false,
        manifest transform: ((inout [String: Any]) -> Void)? = nil
    ) throws -> Fixture {
        let questions = questionData ?? Self.defaultQuestionData
        let images = imageData ?? Self.defaultImageData
        var manifest = makeManifestObject(formatVersion: formatVersion, questionData: questions, imageData: images)
        transform?(&manifest)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])

        var entries: [StoredZipWriter.Entry] = []
        if includeManifest { entries.append(StoredZipWriter.Entry(name: "manifest.json", data: manifestData)) }
        for (category, data) in questions.sorted(by: { $0.key < $1.key }) {
            entries.append(StoredZipWriter.Entry(name: "questions/\(category).jsonl", data: data))
        }
        if includeImages {
            for (file, data) in images.sorted(by: { $0.key < $1.key }) {
                entries.append(StoredZipWriter.Entry(name: "images/\(file)", data: data))
            }
        }
        entries.append(contentsOf: extraEntries)
        if let corruptCRCFor, let index = entries.firstIndex(where: { $0.name == corruptCRCFor }) {
            entries[index].crcOverride = 0xDEAD_BEEF
        }

        let url = try makeTempDirectory().appendingPathComponent("lanjing-bank-test.zip")
        try StoredZipWriter.archive(entries, eocdEntryCount: eocdEntryCount, zip64Sentinel: zip64Sentinel).write(to: url)
        return Fixture(url: url, manifestData: manifestData, questionData: questions, imageData: images)
    }

    /// 按内容生成 manifest(字段与 snapshot.js 的 buildManifest 一致)。
    private func makeManifestObject(formatVersion: Int, questionData: [String: Data], imageData: [String: Data]) -> [String: Any] {
        let byCategory = questionData.mapValues { recordCount($0) }
        let images: [[String: Any]] = imageData.sorted { $0.key < $1.key }.map { file, data in
            ["url": "https://example.test/\(file)", "file": file, "mime": mimeType(of: data),
             "bytes": data.count, "sha256": sha256Hex(data)]
        }
        return [
            "formatVersion": formatVersion,
            "generatedAt": "2026-09-10T00:00:00.000Z",
            "counts": ["questions": byCategory.values.reduce(0, +), "images": images.count, "byCategory": byCategory],
            "images": images,
        ]
    }

    private static let defaultImageData: [String: Data] = [
        "a1b2.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("图片一".utf8),
        "c3d4.png": Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("图片二".utf8),
    ]

    private static let defaultQuestionData: [String: Data] = [
        "言语理解": jsonl([
            questionLine(id: "q1"),
            questionLine(id: "q2", answer: #"["A","C"]"#),
        ]),
        "数字运算": jsonl([questionLine(id: "q3", category: "数字运算")]),
    ]

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BankPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("not-a-bank.zip")
        try data.write(to: url)
        return url
    }

    /// 断言抛出的错误与 `expected` 逐字段相等(比较对象都是测试自己算出来的值)。
    private func assertThrows<T>(
        _ expected: BankPackageError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> T
    ) {
        do {
            _ = try body()
            XCTFail("应当抛出 \(expected),但没有抛错", file: file, line: line)
        } catch let error as BankPackageError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("应当抛出 \(expected),实际抛出 \(error)", file: file, line: line)
        }
    }
}

// MARK: - 夹具构造小工具

/// 一行题目记录(字段与 collector 的 JSONL 对齐;`options` 传空数组可造出无选项记录)。
private func questionLine(id: String, category: String = "言语理解", answer: String = #""A""#, options: [String]? = nil) -> String {
    let slots = options ?? ["<p>A 选项</p>", "<p>B 选项</p>", "<p>C 选项</p>", "<p>D 选项</p>"]
    let encoded = (try? JSONSerialization.data(withJSONObject: slots)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    return """
    {"_id":"\(id)","category":"\(category)","section":"逻辑填空","subCategory":"成语辨析",\
    "question":"<p>题干 \(id)</p>","options":\(encoded),"answer":\(answer),"analysis":"<p>解析</p>",\
    "sourceExamName":"【言语理解（二）】机考题库"}
    """
}

/// 一行行拼成 JSONL,末尾带一个换行(真实产物就是这样)。
private func jsonl(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 数 JSONL 里的记录数(非空行),用来生成 fixtures 的 manifest.counts。
private func recordCount(_ data: Data) -> Int {
    String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .count
}

/// 与 apps/bank/lib/snapshot.js 的 detectMime 同规则(测试侧独立实现)。
private func mimeType(of data: Data) -> String {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
    return "application/octet-stream"
}

private func isImageMagic(_ data: Data) -> Bool {
    mimeType(of: data).hasPrefix("image/")
}

/// 最小 zip writer(仅 STORED):只为造夹具,不做压缩、不写 Zip64。
private struct StoredZipWriter {

    /// 一个待写入的条目。`method` / `crcOverride` 可写坏,用来造错误路径。
    struct Entry {
        let name: String
        let data: Data
        var method: UInt16 = 0
        var crcOverride: UInt32?
        /// 通用位 11:条目名按 UTF-8(快照产物的分类名是中文,靠它才能正确解码)。
        var flags: UInt16 = 0x0800
    }

    /// 写出 zip 字节。`eocdEntryCount` 把 EOCD 的条目数写错(造中央目录损坏),
    /// `zip64Sentinel` 把条目数/偏移/大小写成哨兵值(造 Zip64 拒绝路径)。
    static func archive(_ entries: [Entry], eocdEntryCount: Int? = nil, zip64Sentinel: Bool = false) -> Data {
        var body = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = entry.crcOverride ?? crc32(entry.data)
            let offset = body.count
            body.append(uint32: 0x0403_4B50)
            body.append(uint16: 20)
            body.append(uint16: entry.flags)
            body.append(uint16: entry.method)
            body.append(uint16: 0)          // 修改时间(固定值,保证可重复)
            body.append(uint16: 0x0021)     // 修改日期 1980-01-01
            body.append(uint32: crc)
            body.append(uint32: UInt32(entry.data.count))
            body.append(uint32: UInt32(entry.data.count))
            body.append(uint16: UInt16(name.count))
            body.append(uint16: 0)          // extra field 长度
            body.append(name)
            body.append(entry.data)

            central.append(uint32: 0x0201_4B50)
            central.append(uint16: 20)      // version made by
            central.append(uint16: 20)      // version needed
            central.append(uint16: entry.flags)
            central.append(uint16: entry.method)
            central.append(uint16: 0)
            central.append(uint16: 0x0021)
            central.append(uint32: crc)
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint16: UInt16(name.count))
            central.append(uint16: 0)       // extra
            central.append(uint16: 0)       // comment
            central.append(uint16: 0)       // 起始磁盘号
            central.append(uint16: 0)       // 内部属性
            central.append(uint32: 0x81A4_0000)
            central.append(uint32: UInt32(offset))
            central.append(name)
        }
        let centralOffset = body.count
        body.append(central)

        let count = UInt16(eocdEntryCount ?? entries.count)
        body.append(uint32: 0x0605_4B50)
        body.append(uint16: 0)              // 本磁盘号
        body.append(uint16: 0)              // 中央目录起始磁盘号
        body.append(uint16: zip64Sentinel ? 0xFFFF : count)
        body.append(uint16: zip64Sentinel ? 0xFFFF : count)
        body.append(uint32: zip64Sentinel ? 0xFFFF_FFFF : UInt32(central.count))
        body.append(uint32: zip64Sentinel ? 0xFFFF_FFFF : UInt32(centralOffset))
        body.append(uint16: 0)              // 注释长度
        return body
    }
}

/// CRC32(IEEE,zip 用):测试侧独立实现一份(逐位版,与 BankPackage 内部的表驱动
/// 实现互不依赖,两边算出来一致才说明读侧没算错)。
private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
    }
    return crc ^ 0xFFFF_FFFF
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
