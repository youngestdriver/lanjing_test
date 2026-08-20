package com.qzh.lanjingquiz.Data

import android.content.Context
import com.qzh.lanjingquiz.Domain.BankLogic
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * 本地题库持久化缝(iOS BankStorage 移植):每大类一个 JSONL 文件 + meta.json 提交点 +
 * crawl_log.jsonl。meta 永远最后写 —— 中断的更新留下未 populate 的库,下次进入干净重爬。
 */
interface BankStorage {
    /** 分类文件内容(容错解析 + 按 _id 去重);文件缺失/损坏 → 空。 */
    fun readCategory(category: String): List<BankQuestion>
    /** 增量追加(读改写,原子);空批次 no-op。 */
    fun appendRecords(category: String, records: List<BankQuestion>)
    /** 全量写分类文件;meta.json 由调用方随后 writeMeta(提交点),见 Crawler 刷新提交。 */
    fun writeAll(files: Map<String, List<BankQuestion>>)
    fun readMeta(): BankMeta?
    fun writeMeta(meta: BankMeta)
    /** meta 存在 且 全部 5 个分类文件都在 且 counts 非空。 */
    fun isPopulated(): Boolean
    fun clearAll()
    fun readCrawlLog(): List<CrawlLogEntry>
    fun appendCrawlLog(entry: CrawlLogEntry)
}

/**
 * FileManager 版:filesDir/LanjingQuiz/bank/。JSONL 逐行容错解析(仅 _id 必需、未知键忽略、
 * 损坏尾行丢弃、按 _id 去重);全部写入走临时文件 + rename(原子);synchronized 串行化
 * (后写赢,镜像 iOS actor)。
 */
class FileBankStorage private constructor(
    private val directory: File,
    private val lock: Any,
) : BankStorage {

    constructor(context: Context) : this(File(context.filesDir, "LanjingQuiz/bank"), Any())
    constructor(root: File) : this(root, Any())

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override fun readCategory(category: String): List<BankQuestion> = synchronized(lock) {
        val text = readTextIfPresent(categoryFile(category)) ?: return@synchronized emptyList()
        BankLogic.parseJsonl(text)
    }

    override fun appendRecords(category: String, records: List<BankQuestion>) = synchronized(lock) {
        if (records.isEmpty()) return@synchronized
        val file = categoryFile(category)
        val existing = readTextIfPresent(file) ?: ""
        val lines = buildString {
            append(existing)
            for (record in records) {
                append(json.encodeToString(BankQuestion.serializer(), record))
                append('\n')
            }
        }
        atomicWrite(file, lines.toString())
    }

    /** 先写全部(5 个)分类文件;meta.json 由调用方随后 writeMeta —— 提交点。 */
    override fun writeAll(files: Map<String, List<BankQuestion>>) = synchronized(lock) {
        for ((category, records) in files) {
            val lines = records.joinToString("\n") { json.encodeToString(BankQuestion.serializer(), it) }
            atomicWrite(categoryFile(category), if (lines.isEmpty()) "" else lines + "\n")
        }
    }

    override fun readMeta(): BankMeta? = synchronized(lock) {
        val text = readTextIfPresent(metaFile) ?: return@synchronized null
        runCatching { json.decodeFromString<BankMeta>(text) }.getOrNull()
    }

    override fun writeMeta(meta: BankMeta) = synchronized(lock) {
        atomicWrite(metaFile, json.encodeToString(BankMeta.serializer(), meta))
    }

    override fun isPopulated(): Boolean = synchronized(lock) {
        val meta = readMeta() ?: return@synchronized false
        val allFiles = BankLogic.categories.all { categoryFile(it).isFile }
        allFiles && meta.counts.isNotEmpty()
    }

    override fun clearAll() = synchronized(lock) {
        directory.deleteRecursively()
        Unit
    }

    override fun readCrawlLog(): List<CrawlLogEntry> = synchronized(lock) {
        val text = readTextIfPresent(crawlLogFile) ?: return@synchronized emptyList()
        text.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { line -> runCatching { json.decodeFromString<CrawlLogEntry>(line) }.getOrNull() }
            .toList()
    }

    override fun appendCrawlLog(entry: CrawlLogEntry) = synchronized(lock) {
        val file = crawlLogFile
        val existing = readTextIfPresent(file) ?: ""
        atomicWrite(file, existing + json.encodeToString(CrawlLogEntry.serializer(), entry) + "\n")
    }

    private fun categoryFile(category: String) = File(directory, "$category.jsonl")
    private val metaFile get() = File(directory, "meta.json")
    private val crawlLogFile get() = File(directory, "crawl_log.jsonl")

    private fun readTextIfPresent(file: File): String? {
        if (!file.isFile) return null
        return runCatching { file.readText(Charsets.UTF_8) }.getOrNull()
    }
}

/** 临时文件 + 原子 rename(同目录):写入中断不留半截文件。 */
internal fun atomicWrite(target: File, content: String) {
    target.parentFile?.mkdirs()
    val tmp = File(target.parentFile, target.name + ".tmp")
    tmp.writeText(content, Charsets.UTF_8)
    try {
        Files.move(
            tmp.toPath(), target.toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
        )
    } catch (e: AtomicMoveNotSupportedException) {
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }
}
