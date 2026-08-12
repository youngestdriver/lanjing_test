package com.qzh.lanjingquiz.Data

import android.content.Context
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * 某题型细分的已答进度(注册表键 "category/subCategory" → answeredIDs;
 * spec §3.2 逐字)。answeredIDs 为已揭晓答案的题目 _id(稳定,不受随机顺序影响),写入前去重。
 */
@Serializable
data class PracticeProgress(
    val answeredIDs: List<String> = emptyList(),
)

/** 进度注册表持久化缝(整字典快照)。 */
interface PracticeProgressStore {
    /** 无存档(从未做过任何题或已清除) → 空字典。 */
    suspend fun load(): Map<String, PracticeProgress>
    suspend fun save(progress: Map<String, PracticeProgress>)
    suspend fun clear()
}

/**
 * FileManager 版:filesDir/LanjingQuiz/practice-progress.json。
 * 单线程 I/O 串行化(镜像 iOS actor);JSON 解码容忍 iOS 写出的文件。
 */
class FilePracticeProgressStore private constructor(
    private val url: File,
    private val io: CoroutineDispatcher,
) : PracticeProgressStore {

    constructor(context: Context) : this(File(context.filesDir, "LanjingQuiz/practice-progress.json"), sharedIo)
    constructor(root: File) : this(File(root, "practice-progress.json"), sharedIo)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override suspend fun load(): Map<String, PracticeProgress> = withContext(io) {
        if (!url.isFile) return@withContext emptyMap()
        runCatching { json.decodeFromString<Map<String, PracticeProgress>>(url.readText()) }.getOrNull()
            ?: emptyMap()
    }

    override suspend fun save(progress: Map<String, PracticeProgress>) = withContext(io) {
        atomicWrite(url, json.encodeToString(progress))
    }

    override suspend fun clear() = withContext(io) {
        url.delete()
        Unit
    }

    companion object {
        /** 全部文件存储共享的单线程 I/O(镜像 iOS actor 的串行化语义)。 */
        private val sharedIo = Dispatchers.IO.limitedParallelism(1)
    }
}
