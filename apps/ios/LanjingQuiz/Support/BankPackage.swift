import CryptoKit
import Foundation

/// 题库包(zip)的读取与校验层 —— 纯读取,不碰 SwiftData / UI。
///
/// 包格式的权威定义在 apps/bank/lib/snapshot.js:
///   * 单文件 zip,全部条目 method=0(STORED,不压缩):题图本身已是 PNG/JPEG/GIF
///     这类压缩格式,deflate 省不下空间;iOS 侧只要解析目录、按偏移拷字节即可,
///     不需要实现 inflate。这是刻意取舍,不是遗漏。
///   * 条目三类:manifest.json、questions/<分类>.jsonl ×5(中文名,UTF-8)、
///     images/<文件名> ×N(ASCII 名,但字节真身可能是 PNG/JPEG/GIF,以魔数为准)。
///   * 条目名按 UTF-8 存储且 zip 通用位 11(0x0800)已置位 —— macOS 的 unzip 不认
///     这个位,解出来是乱码;我们自己解析中央目录,按标志位正确解码。
///
/// 打开时只解析中央目录 + manifest.json,4335 张图一张都不进内存;取数时才逐条核
/// CRC32 / 字节数 / manifest 声明的 sha256 —— 用哪张抽哪张。
///
/// 写入侧约束(本层不涉及,但决定了调用顺序):SwiftData 对 @Attribute(.unique)
/// 主键重复插入**不抛错,而是就地 upsert**(见
/// testUniqueIDConflictUpsertsInsteadOfThrowing),所以导入必须先删后插,不能
/// 先插新库再切 current —— 主键重合时新行会静默改写旧版本记录。
struct BankPackage: Sendable {

    // MARK: - 常量

    /// 唯一支持的格式版本;manifest.formatVersion 不等于它就拒绝导入。
    static let supportedFormatVersion = 1

    static let manifestEntryName = "manifest.json"
    static let questionsPrefix = "questions/"
    static let imagesPrefix = "images/"
    static let jsonlSuffix = ".jsonl"

    private static let localSignature: UInt32 = 0x0403_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let utf8NameFlag: UInt16 = 0x0800
    private static let storedMethod: UInt16 = 0
    private static let zip64EntryCountSentinel: Int = 0xFFFF
    private static let zip64ValueSentinel = 0xFFFF_FFFF
    private static let endOfCentralDirectoryLength = 22
    private static let maxCommentLength = 0xFFFF
    private static let localHeaderLength = 30
    private static let centralHeaderLength = 46

    // MARK: - 类型

    /// 中央目录里的一条记录(只有元数据,不含数据本身)。
    struct Entry: Sendable {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    // MARK: - 元数据

    /// 包的来源。按需抽取时重新打开文件,不长期持有 FileHandle —— 否则
    /// BankPackage 就不是 Sendable,导入这种后台任务反而要背线程约束。
    let url: URL

    /// manifest.json 的内容(打开时就解析好:题数、图片清单都从它来)。
    let manifest: BankPackageManifest

    /// 中央目录条目,保持 zip 内的物理顺序:manifest.json → questions/*.jsonl → images/*
    let entries: [Entry]

    /// zip 文件总字节数(边界检查用)。
    private let fileSize: Int
    private let entriesByName: [String: Entry]
    /// manifest 声明的图片:文件名 → 记录(extract 时据此核 bytes/sha256)。
    private let declaredImages: [String: BankPackageImageEntry]

    // MARK: - 打开

    /// 打开题库包:解析中央目录 → 读 manifest.json → 对齐清单与包内实际条目。
    /// 任何一步对不上都抛错,不做「猜」的降级 —— 包坏了必须让用户重下,而不是
    /// 导入一个残库。
    init(url: URL) throws {
        self.url = url
        let fileSize = try Self.fileSize(of: url)
        self.fileSize = fileSize

        let entries = try Self.readCentralDirectory(from: url, fileSize: fileSize)
        var byName: [String: Entry] = [:]
        byName.reserveCapacity(entries.count)
        for entry in entries {
            guard byName.updateValue(entry, forKey: entry.name) == nil else {
                throw BankPackageError.corruptCentralDirectory("条目名重复:\(entry.name)")
            }
        }
        self.entries = entries
        self.entriesByName = byName

        guard let manifestEntry = byName[Self.manifestEntryName] else {
            throw BankPackageError.missingManifest
        }
        let manifestData = try Self.readData(from: url, entry: manifestEntry, fileSize: fileSize)
        try Self.verifyChecksums(entry: manifestEntry, data: manifestData, declared: nil)
        let manifest: BankPackageManifest
        do {
            manifest = try JSONDecoder().decode(BankPackageManifest.self, from: manifestData)
        } catch {
            throw BankPackageError.malformedManifest(Self.describe(error))
        }
        guard manifest.formatVersion == Self.supportedFormatVersion else {
            throw BankPackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        self.manifest = manifest

        var images: [String: BankPackageImageEntry] = [:]
        images.reserveCapacity(manifest.images.count)
        for image in manifest.images {
            try Self.assertSafeFileName(image.file, label: "manifest 图片文件名")
            guard images.updateValue(image, forKey: image.file) == nil else {
                throw BankPackageError.manifestMismatch("manifest 里的图片文件名重复:\(image.file)")
            }
        }
        self.declaredImages = images
        try validateManifestAgainstZip()
    }

    // MARK: - 条目清单

    /// 题目文件条目名(按 zip 内顺序)。分类名从条目名取,不信 manifest 的键。
    var questionFiles: [String] {
        entries.map(\.name).filter { Self.category(fromQuestionFile: $0) != nil }
    }

    /// manifest 声明的图片清单(按 url 排序,与 snapshot.js 产出一致)。
    var imageEntries: [BankPackageImageEntry] { manifest.images }

    // MARK: - 按需抽取

    /// 抽取一个条目的原始字节,并核 CRC32、字节数,以及(图片)manifest 声明的
    /// sha256。图片单张几百 KB、总数 4335,不能全量驻留内存。
    func extract(_ entryName: String) throws -> Data {
        guard let entry = entriesByName[entryName] else {
            throw BankPackageError.missingEntry(entryName)
        }
        let data = try Self.readData(from: url, entry: entry, fileSize: fileSize)
        try Self.verifyChecksums(entry: entry, data: data, declared: declaredImage(for: entry))
        return data
    }

    /// 抽取 manifest 里某张图的字节(等价于 extract("images/" + file),省得调用方手拼前缀)。
    func extractImage(_ image: BankPackageImageEntry) throws -> Data {
        try extract(Self.imagesPrefix + image.file)
    }

    /// 逐分类抽出题目 JSONL 的原始字节(分类名来自条目名)。
    func questionPayloads() throws -> [(category: String, data: Data)] {
        try entries.compactMap { entry in
            guard let category = Self.category(fromQuestionFile: entry.name) else { return nil }
            return (category, try extract(entry.name))
        }
    }

    // MARK: - 解码题目

    /// 全量解码题目,按分类分组。任何一行坏掉都直接报错(带分类 + 行号):
    /// 静默跳过会让 manifest 说的 500 题变成 499 题,而且是用户做到一半才发现。
    ///
    /// 注意 BankQuestion.init(from:) 对 category/section/question/options 等字段
    /// 一律 try? 兜底(坏字段静默降级成空值),所以「行数对得上」不等于「题能用」:
    /// 这里额外要求每条记录至少有 1 个选项、且 _id 非空(空 _id 会在 SwiftData 的
    /// unique 主键上塌成同一行)。
    func questions() throws -> [String: [BankQuestion]] {
        let decoder = JSONDecoder()
        var result: [String: [BankQuestion]] = [:]
        for (category, data) in try questionPayloads() {
            let questions = try Self.decodeQuestions(data, category: category, decoder: decoder)
            guard let declared = manifest.counts.byCategory[category] else {
                throw BankPackageError.manifestMismatch("包内有 manifest 未声明的分类:\(category)")
            }
            guard questions.count == declared else {
                throw BankPackageError.manifestMismatch(
                    "分类 \(category) 实际解析出 \(questions.count) 题,manifest 声明 \(declared) 题"
                )
            }
            result[category] = questions
        }
        let total = result.values.reduce(0) { $0 + $1.count }
        guard total == manifest.counts.questions else {
            throw BankPackageError.manifestMismatch("实际解析出 \(total) 题,manifest 声明 \(manifest.counts.questions) 题")
        }
        return result
    }

    // MARK: - 校验

    /// 打开时就把「manifest 声明」与「zip 实际内容」对齐:缺文件、多文件、counts
    /// 自相矛盾全部拦掉,不放「清单说 3065 题、包里只有 3064」的包进导入流程。
    private func validateManifestAgainstZip() throws {
        guard manifest.counts.images == manifest.images.count else {
            throw BankPackageError.manifestMismatch(
                "counts.images=\(manifest.counts.images) 与 images 数组长度 \(manifest.images.count) 不一致"
            )
        }
        let declaredTotal = manifest.counts.byCategory.values.reduce(0, +)
        guard declaredTotal == manifest.counts.questions else {
            throw BankPackageError.manifestMismatch(
                "counts.questions=\(manifest.counts.questions) 与 byCategory 合计 \(declaredTotal) 不一致"
            )
        }
        for category in manifest.counts.byCategory.keys {
            let name = Self.questionsPrefix + category + Self.jsonlSuffix
            guard entriesByName[name] != nil else {
                throw BankPackageError.manifestMismatch("manifest 声明了分类 \(category),但包里没有 \(name)")
            }
        }
        for entry in entries where entry.name.hasPrefix(Self.questionsPrefix) {
            guard let category = Self.category(fromQuestionFile: entry.name),
                  manifest.counts.byCategory[category] != nil else {
                throw BankPackageError.manifestMismatch("包里多出 manifest 未声明的题目文件:\(entry.name)")
            }
        }
        for image in manifest.images {
            let name = Self.imagesPrefix + image.file
            guard entriesByName[name] != nil else {
                throw BankPackageError.manifestMismatch("manifest 声明的图片在包里缺失:\(name)")
            }
        }
        for entry in entries where entry.name.hasPrefix(Self.imagesPrefix)
            && declaredImages[String(entry.name.dropFirst(Self.imagesPrefix.count))] == nil {
            throw BankPackageError.manifestMismatch("包里多出 manifest 未声明的图片:\(entry.name)")
        }
    }

    /// manifest 声明该条目是图片时给出记录(否则 nil,只做 CRC/字节数校验)。
    private func declaredImage(for entry: Entry) -> BankPackageImageEntry? {
        guard entry.name.hasPrefix(Self.imagesPrefix) else { return nil }
        return declaredImages[String(entry.name.dropFirst(Self.imagesPrefix.count))]
    }

    /// 一条条目的完整体检:CRC32(与中央目录声明比)→ 字节数(与中央目录、与
    /// manifest 的 bytes 比)→ sha256(manifest 声明的,只有图片有)。
    private static func verifyChecksums(entry: Entry, data: Data, declared: BankPackageImageEntry?) throws {
        let actual = crc32(data)
        guard actual == entry.crc32 else {
            throw BankPackageError.crcMismatch(entry: entry.name, expected: entry.crc32, actual: actual)
        }
        guard data.count == entry.uncompressedSize else {
            throw BankPackageError.byteCountMismatch(entry: entry.name, expected: entry.uncompressedSize, actual: data.count)
        }
        guard let declared else { return }
        guard data.count == declared.bytes else {
            throw BankPackageError.byteCountMismatch(entry: entry.name, expected: declared.bytes, actual: data.count)
        }
        let digest = sha256Hex(data)
        guard digest == declared.sha256.lowercased() else {
            throw BankPackageError.sha256Mismatch(entry: entry.name)
        }
    }

    /// 逐行 JSON 解码一个分类的 JSONL。
    private static func decodeQuestions(_ data: Data, category: String, decoder: JSONDecoder) throws -> [BankQuestion] {
        // 行号按物理行算:空行(产物末尾有一个)只跳过、不占号,报出来的行号
        // 与用户在编辑器里看到的一致。
        guard let text = String(data: data, encoding: .utf8) else {
            throw BankPackageError.malformedJSONL(category: category, line: 1, reason: "文件不是合法 UTF-8")
        }
        var questions: [BankQuestion] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let number = index + 1
            let question: BankQuestion
            do {
                question = try decoder.decode(BankQuestion.self, from: Data(line.utf8))
            } catch let error as DecodingError {
                switch error {
                case .keyNotFound(let key, _):
                    throw BankPackageError.invalidQuestion(
                        category: category, line: number, reason: "缺少关键字段 \(key.stringValue)"
                    )
                case .typeMismatch(let type, let context):
                    throw BankPackageError.invalidQuestion(
                        category: category, line: number,
                        reason: "字段 \(path(context.codingPath)) 类型不是 \(type)"
                    )
                default:
                    throw BankPackageError.malformedJSONL(category: category, line: number, reason: describe(error))
                }
            } catch {
                throw BankPackageError.malformedJSONL(category: category, line: number, reason: describe(error))
            }
            guard !question.options.isEmpty else {
                // options 缺失/类型不对会被 BankQuestion.init(from:) 静默降级成空
                // 数组,只数行数挡不住「校验全绿,导入的题却没有选项」。
                throw BankPackageError.invalidQuestion(
                    category: category, line: number, reason: "记录没有任何选项(options 缺失或为空)"
                )
            }
            guard !question.id.isEmpty else {
                throw BankPackageError.invalidQuestion(category: category, line: number, reason: "_id 为空")
            }
            questions.append(question)
        }
        return questions
    }

    // MARK: - zip 解析

    /// 解析中央目录。只读 EOCD 附近的尾巴和中央目录本身,不碰条目数据。
    private static func readCentralDirectory(from url: URL, fileSize: Int) throws -> [Entry] {
        guard fileSize >= endOfCentralDirectoryLength else {
            throw BankPackageError.notAZip("\(url.lastPathComponent) 只有 \(fileSize) 字节,放不下 zip 的最小结构")
        }
        // EOCD 在文件末尾,后面最多跟 65535 字节注释,回扫这一段就够。
        let tailLength = min(fileSize, endOfCentralDirectoryLength + maxCommentLength)
        let tail = try read(from: url, at: fileSize - tailLength, count: tailLength)
        var eocd = -1
        for index in stride(from: tailLength - endOfCentralDirectoryLength, through: 0, by: -1)
        where (try? ZipBytes.u32(tail, index)) == endOfCentralDirectorySignature {
            eocd = index
            break
        }
        guard eocd >= 0 else {
            throw BankPackageError.notAZip("\(url.lastPathComponent) 找不到 EOCD(不是 zip,或已损坏)")
        }

        let diskEntries = Int(try ZipBytes.u16(tail, eocd + 8))
        let entryCount = Int(try ZipBytes.u16(tail, eocd + 10))
        let centralSize = Int(try ZipBytes.u32(tail, eocd + 12))
        let centralOffset = Int(try ZipBytes.u32(tail, eocd + 16))
        // Zip64:条目数/偏移/大小用哨兵值表示「真值在 Zip64 记录里」。快照格式用不到
        // (4341 条目远够),遇到哨兵直接拒绝,而不是把 0xFFFFFFFF 当真实值读。
        guard entryCount != zip64EntryCountSentinel, diskEntries != zip64EntryCountSentinel,
              centralSize != zip64ValueSentinel, centralOffset != zip64ValueSentinel else {
            throw BankPackageError.zip64Unsupported(
                "中央目录使用 Zip64(条目数 \(entryCount)、偏移 \(centralOffset)、大小 \(centralSize))"
            )
        }
        guard diskEntries == entryCount else {
            throw BankPackageError.corruptCentralDirectory("EOCD 条目数不一致:本盘 \(diskEntries) / 总数 \(entryCount)")
        }
        guard centralOffset + centralSize <= fileSize else {
            throw BankPackageError.corruptCentralDirectory("中央目录越界:\(centralOffset)+\(centralSize) > \(fileSize)")
        }

        let central = try read(from: url, at: centralOffset, count: centralSize)
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0
        for index in 0..<entryCount {
            guard cursor + centralHeaderLength <= central.count else {
                throw BankPackageError.corruptCentralDirectory("中央目录第 \(index + 1) 条越界(偏移 \(cursor),共 \(central.count) 字节)")
            }
            guard (try? ZipBytes.u32(central, cursor)) == centralSignature else {
                throw BankPackageError.corruptCentralDirectory("中央目录第 \(index + 1) 条签名非法(偏移 \(cursor))")
            }
            let flags = try ZipBytes.u16(central, cursor + 8)
            let method = try ZipBytes.u16(central, cursor + 10)
            let crc = try ZipBytes.u32(central, cursor + 16)
            let compressedSize = Int(try ZipBytes.u32(central, cursor + 20))
            let uncompressedSize = Int(try ZipBytes.u32(central, cursor + 24))
            let nameLength = Int(try ZipBytes.u16(central, cursor + 28))
            let extraLength = Int(try ZipBytes.u16(central, cursor + 30))
            let commentLength = Int(try ZipBytes.u16(central, cursor + 32))
            let localOffset = Int(try ZipBytes.u32(central, cursor + 42))
            guard cursor + centralHeaderLength + nameLength + extraLength + commentLength <= central.count else {
                throw BankPackageError.corruptCentralDirectory(
                    "中央目录第 \(index + 1) 条字段越界(name \(nameLength) / extra \(extraLength) / comment \(commentLength))"
                )
            }
            let name = try decodeName(try ZipBytes.slice(central, cursor + centralHeaderLength, nameLength), flags: flags, index: index)
            cursor += centralHeaderLength + nameLength + extraLength + commentLength

            // 压缩条目(deflate 等)与 Zip64 哨兵方法值都不支持:快照全 STORED。
            guard method == storedMethod else {
                throw BankPackageError.unsupportedCompressionMethod(entry: name, method: method)
            }
            guard compressedSize != zip64ValueSentinel, uncompressedSize != zip64ValueSentinel,
                  localOffset != zip64ValueSentinel else {
                throw BankPackageError.zip64Unsupported("条目 \(name) 的尺寸/偏移是 Zip64 哨兵")
            }
            guard compressedSize == uncompressedSize else {
                throw BankPackageError.corruptCentralDirectory(
                    "条目 \(name) 压缩大小 \(compressedSize) != 原始大小 \(uncompressedSize)(STORED 必须相等)"
                )
            }
            try assertSafeEntryName(name)
            guard localOffset + localHeaderLength <= fileSize else {
                throw BankPackageError.corruptCentralDirectory("条目 \(name) 本地头越界(偏移 \(localOffset))")
            }
            entries.append(Entry(
                name: name, flags: flags, method: method, crc32: crc,
                compressedSize: compressedSize, uncompressedSize: uncompressedSize, localHeaderOffset: localOffset
            ))
        }
        return entries
    }

    /// 读一条条目的数据段。中央目录里的 offset 指向**本地头**,数据要从本地头的
    /// 名字/extra 长度算起(本地头与中央目录各存一份,以本地头为准)。
    private static func readData(from url: URL, entry: Entry, fileSize: Int) throws -> Data {
        let handle = try open(url)
        defer { try? handle.close() }
        let header = try read(handle, at: entry.localHeaderOffset, count: localHeaderLength)
        guard (try? ZipBytes.u32(header, 0)) == localSignature else {
            throw BankPackageError.corruptCentralDirectory("条目 \(entry.name) 本地头签名非法(偏移 \(entry.localHeaderOffset))")
        }
        let method = try ZipBytes.u16(header, 8)
        guard method == storedMethod else {
            throw BankPackageError.unsupportedCompressionMethod(entry: entry.name, method: method)
        }
        let nameLength = Int(try ZipBytes.u16(header, 26))
        let extraLength = Int(try ZipBytes.u16(header, 28))
        let dataOffset = entry.localHeaderOffset + localHeaderLength + nameLength + extraLength
        guard dataOffset + entry.uncompressedSize <= fileSize else {
            throw BankPackageError.corruptCentralDirectory("条目 \(entry.name) 数据越界:\(dataOffset)+\(entry.uncompressedSize) > \(fileSize)")
        }
        return try read(handle, at: dataOffset, count: entry.uncompressedSize)
    }

    /// 条目名按 UTF-8 解码。通用位 11(0x0800)表示「名字是 UTF-8」—— 快照的中文
    /// 分类名靠它(macOS 的 unzip 不认这个位,所以命令行解出来是乱码)。未置位的
    /// 罕见情况先按 UTF-8 试,latin1 兜底(latin1 解码不会失败)。
    private static func decodeName(_ bytes: Data, flags: UInt16, index: Int) throws -> String {
        if flags & utf8NameFlag != 0 {
            guard let name = String(data: bytes, encoding: .utf8) else {
                throw BankPackageError.corruptCentralDirectory("中央目录第 \(index + 1) 条条目名不是合法 UTF-8")
            }
            return name
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    /// 条目名安全检查:zip 条目名是外部输入,绝对路径 / `..` 穿越 / 反斜杠 / NUL
    /// 一律拒绝 —— 否则将来「解包到目录」的调用方会被写到包外。
    private static func assertSafeEntryName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
            throw BankPackageError.unsafeEntryName(name)
        }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw BankPackageError.unsafeEntryName(name)
            }
        }
    }

    /// 只接受纯文件名(manifest 声明的图片文件名不能带任何路径成分)。
    private static func assertSafeFileName(_ file: String, label: String) throws {
        guard !file.isEmpty, file != ".", file != "..",
              !file.contains("/"), !file.contains("\\"), !file.contains("\0") else {
            throw BankPackageError.unsafeEntryName("\(label):\(file)")
        }
    }

    /// "questions/言语理解.jsonl" → "言语理解";不是这种形状返回 nil。
    private static func category(fromQuestionFile name: String) -> String? {
        guard name.hasPrefix(questionsPrefix), name.hasSuffix(jsonlSuffix) else { return nil }
        let category = name.dropFirst(questionsPrefix.count).dropLast(jsonlSuffix.count)
        return category.isEmpty ? nil : String(category)
    }

    // MARK: - 字节工具

    private static func fileSize(of url: URL) throws -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else {
                throw BankPackageError.notAZip("读不到 \(url.lastPathComponent) 的文件大小")
            }
            return size
        } catch let error as BankPackageError {
            throw error
        } catch {
            throw BankPackageError.notAZip("打不开 \(url.path):\(error.localizedDescription)")
        }
    }

    private static func open(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw BankPackageError.notAZip("打不开 \(url.path):\(error.localizedDescription)")
        }
    }

    private static func read(from url: URL, at offset: Int, count: Int) throws -> Data {
        let handle = try open(url)
        defer { try? handle.close() }
        return try read(handle, at: offset, count: count)
    }

    private static func read(_ handle: FileHandle, at offset: Int, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BankPackageError.corruptCentralDirectory("读取偏移 \(offset) 的 \(count) 字节失败(文件被截断?)")
        }
        return data
    }

    /// CRC32(IEEE,zip 用),与 apps/bank/lib/snapshot.js 的表驱动实现一致。
    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 解码错误 → 一行能看懂的说明(DecodingError 默认的 description 是多行 dump)。
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath + [key]))"
        case .typeMismatch(let type, let context):
            return "字段 \(path(context.codingPath)) 类型不是 \(type)"
        case .valueNotFound(let type, let context):
            return "字段 \(path(context.codingPath)) 缺失(期望 \(type))"
        case .dataCorrupted(let context):
            return "JSON 损坏:\(context.debugDescription)"
        @unknown default:
            return "\(decoding)"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let names = codingPath.map(\.stringValue)
        return names.isEmpty ? "(根)" : names.joined(separator: ".")
    }

    /// 小端读取器:中央目录/本地头都是外部输入,越界必须是抛错而不是崩溃。
    private enum ZipBytes {
        static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
            try require(data, offset, 2)
            let index = data.startIndex + offset
            return UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
        }

        static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
            try require(data, offset, 4)
            let index = data.startIndex + offset
            return UInt32(data[index])
                | (UInt32(data[index + 1]) << 8)
                | (UInt32(data[index + 2]) << 16)
                | (UInt32(data[index + 3]) << 24)
        }

        static func slice(_ data: Data, _ offset: Int, _ length: Int) throws -> Data {
            try require(data, offset, length)
            let start = data.startIndex + offset
            return Data(data[start ..< (start + length)])
        }

        private static func require(_ data: Data, _ offset: Int, _ length: Int) throws {
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw BankPackageError.corruptCentralDirectory("读取 \(offset)+\(length) 越界(共 \(data.count) 字节)")
            }
        }
    }
}

// MARK: - manifest 结构

/// manifest.json 的结构,字段与 apps/bank/lib/snapshot.js 的 buildManifest 一一对应。
struct BankPackageManifest: Decodable, Sendable {

    struct Counts: Decodable, Sendable {
        let questions: Int
        let images: Int
        /// 分类 → 题数。既是逐类计数,也是「包里有哪几个题目文件」的清单。
        let byCategory: [String: Int]
    }

    let formatVersion: Int
    let generatedAt: String
    let counts: Counts
    let images: [BankPackageImageEntry]
}

/// manifest.images 的一项:url → 包内文件(默认 sha1(url).png,但真实类型以字节
/// 魔数为准,mime 由打包侧嗅探后写死)。
struct BankPackageImageEntry: Decodable, Sendable {
    let url: String
    let file: String
    let mime: String
    let bytes: Int
    let sha256: String
}

// MARK: - 错误

/// 题库包读取失败的所有形态。读取层「宁可拒绝、不猜」:任何一条对不上都抛错,
/// 由调用方决定是提示用户重下,还是回退到旧库。
enum BankPackageError: LocalizedError, Equatable {
    /// 打不开,或者不是 zip(找不到 EOCD / 结构放不下)。
    case notAZip(String)
    /// Zip64(条目数/尺寸/偏移是 0xFFFF / 0xFFFFFFFF 哨兵)。快照格式用不到。
    case zip64Unsupported(String)
    /// 中央目录/本地头结构损坏:越界、签名非法、条目数不符、条目名重复。
    case corruptCentralDirectory(String)
    /// method != 0:快照是全 STORED 的,压缩条目与 Zip64 哨兵方法值都不接受。
    case unsupportedCompressionMethod(entry: String, method: UInt16)
    /// 条目名是绝对路径 / 含 `..` 穿越 / 反斜杠 / NUL。
    case unsafeEntryName(String)
    /// 要找的条目不在包里。
    case missingEntry(String)
    /// 包根缺 manifest.json。
    case missingManifest
    /// manifest.json 不是合法 JSON,或缺少必需字段。
    case malformedManifest(String)
    /// manifest.formatVersion 不是 supportedFormatVersion。
    case unsupportedFormatVersion(Int)
    /// manifest 与 zip 实际内容不一致:counts 自相矛盾、缺/多文件、题数与 JSONL 行数不符。
    case manifestMismatch(String)
    case crcMismatch(entry: String, expected: UInt32, actual: UInt32)
    case byteCountMismatch(entry: String, expected: Int, actual: Int)
    case sha256Mismatch(entry: String)
    /// JSONL 某一行不是合法 JSON。
    case malformedJSONL(category: String, line: Int, reason: String)
    /// 某一行能解析成 BankQuestion,但关键字段缺失/非法(如没有任何选项、_id 为空)。
    case invalidQuestion(category: String, line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .notAZip(let detail):
            return "这不是题库包:\(detail)"
        case .zip64Unsupported(let detail):
            return "题库包使用了不支持的 Zip64 结构:\(detail)"
        case .corruptCentralDirectory(let detail):
            return "题库包已损坏:\(detail)"
        case .unsupportedCompressionMethod(let entry, let method):
            return "题库包条目 \(entry) 不是 STORED(method=\(method)),本格式要求全部不压缩"
        case .unsafeEntryName(let name):
            return "题库包条目名不安全:\(name)"
        case .missingEntry(let name):
            return "题库包里找不到条目:\(name)"
        case .missingManifest:
            return "题库包缺少 manifest.json"
        case .malformedManifest(let detail):
            return "题库包 manifest.json 无法解析:\(detail)"
        case .unsupportedFormatVersion(let version):
            return "题库包格式版本 \(version) 不受支持(本 App 只认 \(BankPackage.supportedFormatVersion))"
        case .manifestMismatch(let detail):
            return "题库包清单与内容不一致:\(detail)"
        case .crcMismatch(let entry, let expected, let actual):
            return "题库包条目 \(entry) 校验失败:CRC32 期望 \(String(format: "%08x", expected)),实际 \(String(format: "%08x", actual))"
        case .byteCountMismatch(let entry, let expected, let actual):
            return "题库包条目 \(entry) 校验失败:字节数期望 \(expected),实际 \(actual)"
        case .sha256Mismatch(let entry):
            return "题库包条目 \(entry) 校验失败:sha256 与 manifest 记录不符"
        case .malformedJSONL(let category, let line, let reason):
            return "题库 \(category).jsonl 第 \(line) 行不是合法 JSON:\(reason)"
        case .invalidQuestion(let category, let line, let reason):
            return "题库 \(category).jsonl 第 \(line) 行不可用:\(reason)"
        }
    }
}
