package com.qzh.lanjingquiz.Data

import android.content.Context
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.descriptors.element
import kotlinx.serialization.encodeToString
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.io.File

/**
 * 一次练习会话(iOS PracticeSession 移植)。per-question 状态在 answers(index 与 questions 对齐);
 * JSON 键 category/subCategory/questions/index/answers 逐字 spec §3.2。
 * selected 是集合语义 —— 读入排序归一、写出排序(iOS 写出的 Set 编码顺序不定,不比较数组顺序)。
 */
@Serializable
data class PracticeSession(
    val category: String,
    val subCategory: String,
    val questions: List<BankQuestion>,
    val index: Int = 0,
    val answers: List<PracticeAnswer> = questions.map { PracticeAnswer() },
) {
    val isFinished: Boolean get() = index >= questions.size
    val progress: Double get() = if (questions.isEmpty()) 0.0 else index.toDouble() / questions.size

    // 由 answers 派生,summary 与答题卡统计永不漂移;无答案题(correct == nil)不计为答错
    val rightCount: Int get() = answers.count { it.correct == true }
    val wrongCount: Int get() = answers.count { it.correct == false }
    val answeredCount: Int get() = answers.count { it.revealed }
}

/**
 * 一题的作答状态;correct 三态 true/false/null(null 且 revealed = 无答案记录)。
 * 序列化:selected 写出排序;correct 为 null 时键缺省(与 iOS 编码一致),解码容忍 null/缺失/乱序。
 */
@Serializable(with = PracticeAnswer.Serializer::class)
data class PracticeAnswer(
    val selected: List<String> = emptyList(),
    val revealed: Boolean = false,
    val correct: Boolean? = null,
) {
    object Serializer : KSerializer<PracticeAnswer> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("PracticeAnswer") {
            element<String>("selected")
            element<Boolean>("revealed")
            element<Boolean>("correct")
        }

        override fun serialize(encoder: Encoder, value: PracticeAnswer) {
            val json = encoder as? JsonEncoder ?: error("PracticeAnswer only works with JSON")
            json.encodeJsonElement(buildJsonObject {
                put("selected", buildJsonArray { value.selected.sorted().forEach { add(JsonPrimitive(it)) } })
                put("revealed", value.revealed)
                value.correct?.let { put("correct", it) }
            })
        }

        override fun deserialize(decoder: Decoder): PracticeAnswer {
            val json = decoder as? JsonDecoder ?: error("PracticeAnswer only works with JSON")
            val el = json.decodeJsonElement()
            if (el !is JsonObject) return PracticeAnswer()
            val selected = (el["selected"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                ?.sorted()
                ?: emptyList()
            val revealed = (el["revealed"] as? JsonPrimitive)?.contentOrNull
                ?.toBooleanStrictOrNull() ?: false
            val correct = (el["correct"] as? JsonPrimitive)?.contentOrNull
                ?.toBooleanStrictOrNull()
            return PracticeAnswer(selected, revealed, correct)
        }
    }
}

/** 练习会话持久化缝(存档:恢复/保存/清除)。 */
interface PracticeSessionStore {
    /** nil = 无存档(首次进入或已清除)。 */
    suspend fun load(): PracticeSession?
    suspend fun save(session: PracticeSession)
    suspend fun clear()
}

/**
 * FileManager 版:filesDir/LanjingQuiz/practice-session.json。
 * 单线程 I/O 串行化 save/load(后写赢,镜像 iOS actor);JSON 编解码容忍 iOS 写出的文件。
 */
class FilePracticeSessionStore private constructor(
    private val url: File,
    private val io: CoroutineDispatcher,
) : PracticeSessionStore {

    constructor(context: Context) : this(File(context.filesDir, "LanjingQuiz/practice-session.json"), sharedIo)
    constructor(root: File) : this(File(root, "practice-session.json"), sharedIo)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override suspend fun load(): PracticeSession? = withContext(io) {
        if (!url.isFile) return@withContext null
        runCatching { json.decodeFromString<PracticeSession>(url.readText()) }.getOrNull()
    }

    override suspend fun save(session: PracticeSession) = withContext(io) {
        atomicWrite(url, json.encodeToString(PracticeSession.serializer(), session))
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
