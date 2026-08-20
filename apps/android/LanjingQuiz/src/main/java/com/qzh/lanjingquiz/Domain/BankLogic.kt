package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.PracticeProgress
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Data.normalized
import com.qzh.lanjingquiz.Support.SplitMix64
import kotlinx.serialization.json.Json

/**
 * 练习题库纯逻辑(iOS BankLogic.swift 移植):五大类常量/JSONL 容错解析/恢复规则/
 * 组合题保序洗牌/进度聚合。文件名字恒从 categories 派生,绝不从 meta.targets 派生。
 */
object BankLogic {

    /** 五大类中文串(数据契约键,不可本地化)。 */
    val categories: List<String> = listOf("言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型")

    const val DEFAULT_CATEGORY = "未分类"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * 按行容错解析:空行跳过、损坏行丢弃(爬取器保证只有尾行可能损坏)、按 _id 去重(first wins)、
     * question/stem/analysis 图片 src 归一化。
     */
    fun parseJsonl(text: String): List<BankQuestion> =
        text.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { line -> runCatching { json.decodeFromString<BankQuestion>(line) }.getOrNull() }
            .map { it.normalized() }
            .distinctBy { it.id }
            .toList()

    /**
     * 存档可恢复 iff category/subCategory 相等 且 未完成 且 存档题目 ID 集合 == 当前筛选后
     * 题目 ID 集合(顺序无关)。恢复后不复洗、不重复持久化。
     */
    fun resumeCandidate(
        saved: PracticeSession?,
        category: String,
        subCategory: String,
        ordered: List<BankQuestion>,
    ): PracticeSession? {
        val session = saved ?: return null
        if (session.category != category || session.subCategory != subCategory) return null
        if (session.isFinished) return null
        if (session.questions.map { it.id }.toSet() != ordered.map { it.id }.toSet()) return null
        return session
    }

    /**
     * 组合题(资料分析,同 stem 大序号)保持相邻、组内顺序不变的洗牌:组作为单元打乱;
     * 无 stem 的题是单题单元,故无 stem 的题库 = 普通洗牌。
     */
    fun shuffledKeepingGroups(questions: List<BankQuestion>, rng: SplitMix64): List<BankQuestion> {
        val indexByStem = mutableMapOf<String, Int>()
        val units = mutableListOf<MutableList<BankQuestion>>()
        for (question in questions) {
            val stem = question.stem
            if (!stem.isNullOrEmpty() && indexByStem.containsKey(stem)) {
                units[indexByStem.getValue(stem)].add(question)
                continue
            }
            if (!stem.isNullOrEmpty()) indexByStem[stem] = units.size
            units.add(mutableListOf(question))
        }
        return units.shuffled(rng).flatten()
    }

    /** 种子便捷入口(会话级随机种子由 UI 层生成,spec §3.6 SplitMix64)。 */
    fun groupShuffleQuestions(questions: List<BankQuestion>, seed: ULong): List<BankQuestion> =
        shuffledKeepingGroups(questions, SplitMix64(seed))

    /** 某题型细分的已答数(跨会话累计)。 */
    fun answeredCount(progress: Map<String, PracticeProgress>, category: String, subCategory: String): Int =
        progress["$category/$subCategory"]?.answeredIDs?.size ?: 0

    /** 某大类下所有题型细分的已答数之和(键前缀聚合)。 */
    fun answeredCount(progress: Map<String, PracticeProgress>, category: String): Int =
        progress.filterKeys { it.startsWith("$category/") }.values.sumOf { it.answeredIDs.size }
}
