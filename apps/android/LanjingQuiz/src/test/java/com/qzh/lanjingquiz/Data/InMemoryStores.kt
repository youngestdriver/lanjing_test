package com.qzh.lanjingquiz.Data

import com.qzh.lanjingquiz.Domain.BankLogic
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json

/** JVM 单测用内存实现,与 SecureStore 相同接口语义(供后续任务测试复用)。 */
class InMemorySecureStore : SecureStoreLike {
    private val map = mutableMapOf<String, String>()
    override fun getString(key: String): String? = map[key]
    override fun putString(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
}

/** JVM 单测用内存实现,与 SettingsStore 相同接口语义(供后续任务测试复用)。 */
class InMemorySettingsStore : SettingsStore {
    private val strings = mutableMapOf<String, String>()
    private val booleans = mutableMapOf<String, Boolean>()

    override fun getString(key: String, default: String?): String? = strings[key] ?: default
    override fun putString(key: String, value: String) { strings[key] = value }
    override fun getBoolean(key: String, default: Boolean): Boolean = booleans[key] ?: default
    override fun putBoolean(key: String, value: Boolean) { booleans[key] = value }
    override fun remove(key: String) {
        strings.remove(key)
        booleans.remove(key)
    }
}

/**
 * JVM 单测用内存题库(iOS FakeBankStorage 移植):categoryTexts 为 JSONL 原文
 * (与真实盘面一致,走 BankLogic.parseJsonl 容错解析),meta/populated 手工置位。
 */
class InMemoryBankStorage : BankStorage {
    val categoryTexts = mutableMapOf<String, String>()
    var meta: BankMeta? = null
    var populated: Boolean = false
    var clearCount = 0
    val crawlLog = mutableListOf<CrawlLogEntry>()
    val writtenFiles = mutableMapOf<String, List<BankQuestion>>()

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun setCategory(category: String, questions: List<BankQuestion>) {
        categoryTexts[category] = questions.joinToString("\n") {
            json.encodeToString(BankQuestion.serializer(), it)
        } + "\n"
    }

    override fun readCategory(category: String): List<BankQuestion> =
        BankLogic.parseJsonl(categoryTexts[category] ?: "")

    override fun appendRecords(category: String, records: List<BankQuestion>) {
        val existing = readCategory(category)
        setCategory(category, existing + records)
    }

    override fun writeAll(files: Map<String, List<BankQuestion>>) {
        files.forEach { (category, records) -> setCategory(category, records) }
        writtenFiles.putAll(files)
    }

    override fun readMeta(): BankMeta? = meta
    override fun writeMeta(meta: BankMeta) { this.meta = meta }

    override fun isPopulated(): Boolean = populated

    override fun clearAll() {
        clearCount++
        categoryTexts.clear()
        writtenFiles.clear()
        meta = null
        crawlLog.clear()
    }

    override fun readCrawlLog(): List<CrawlLogEntry> = crawlLog.toList()
    override fun appendCrawlLog(entry: CrawlLogEntry) { crawlLog += entry }
}

/**
 * JVM 单测用内存会话存档(iOS FakePracticeSessionStore 移植):记录 save/clear,
 * 可预置("seed")恢复存档;awaitSaveCount 屏障匹配 iOS actor 语义
 * (VM 的持久化 Task 是 fire-and-forget,测试先推进调度器再等待落盘)。
 */
class FakePracticeSessionStore : PracticeSessionStore {
    var stored: PracticeSession? = null
    var saveCount = 0
    var clearCount = 0

    override suspend fun load(): PracticeSession? = stored
    override suspend fun save(session: PracticeSession) {
        stored = session
        saveCount++
    }
    override suspend fun clear() {
        stored = null
        clearCount++
    }

    suspend fun awaitSaveCount(target: Int) { while (saveCount < target) delay(1) }
    suspend fun awaitClearCount(target: Int) { while (clearCount < target) delay(1) }
}

/** JVM 单测用内存进度注册表(同 FakePracticeSessionStore 语义)。 */
class FakePracticeProgressStore : PracticeProgressStore {
    var stored: Map<String, PracticeProgress>? = emptyMap()
    var saveCount = 0
    var clearCount = 0

    override suspend fun load(): Map<String, PracticeProgress> = stored ?: emptyMap()
    override suspend fun save(progress: Map<String, PracticeProgress>) {
        stored = progress
        saveCount++
    }
    override suspend fun clear() {
        stored = null
        clearCount++
    }

    suspend fun awaitSaveCount(target: Int) { while (saveCount < target) delay(1) }
    suspend fun awaitClearCount(target: Int) { while (clearCount < target) delay(1) }
}
