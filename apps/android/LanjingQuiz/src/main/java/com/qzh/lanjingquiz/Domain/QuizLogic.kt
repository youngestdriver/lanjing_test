package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Network.QuestionDto

/** 题目判定/字母映射纯函数 —— iOS QuizLogic.swift + Question(answerKey) 移植。 */
enum class OptionMarker { Correct, Wrong }

object QuizLogic {

    const val STATE_UNANSWERED = "unanswered"
    const val STATE_RIGHT = "right"
    const val STATE_ERROR = "error"

    private val letters = listOf("A", "B", "C", "D")

    /**
     * 正确字母(key1..key4 == "1" 优先):>1 → 多选;0 个则回退 test_ans_right 非空 → [回退值];否则空 = 无答案。
     */
    fun correctLetters(dto: QuestionDto): List<String> {
        val keys = listOf(dto.key1, dto.key2, dto.key3, dto.key4)
        val found = letters.filterIndexed { i, _ -> keys.getOrNull(i)?.value == "1" }
        if (found.isNotEmpty()) return found
        return if (dto.testAnsRight.isNotBlank()) listOf(dto.testAnsRight) else emptyList()
    }

    /** 单选答案字母;多选/无答案 → null。 */
    fun letterFor(dto: QuestionDto): String? = correctLetters(dto).takeIf { it.size == 1 }?.first()

    /** 正确字母数 > 1 = 多选。 */
    fun isMulti(dto: QuestionDto): Boolean = correctLetters(dto).size > 1

    /** 是否有标准答案(全 0 且无回退 = 无答案题)。 */
    fun isGradable(dto: QuestionDto): Boolean = correctLetters(dto).isNotEmpty()

    /**
     * 判定上色(仅作答后):选中且(单选错 或 不在正确答案集)→ Wrong;在正确答案集 → Correct;其余 → null。
     * 多选答错时参考答案仍 ✅(isCorrect=true 不受 questionState 影响)。
     */
    fun optionResult(
        isAnswered: Boolean,
        isSelected: Boolean,
        isCorrect: Boolean?,
        isMulti: Boolean,
        questionState: String,
    ): OptionMarker? {
        if (!isAnswered) return null
        if (isSelected && ((!isMulti && questionState == STATE_ERROR) || isCorrect != true)) {
            return OptionMarker.Wrong
        }
        if (isCorrect == true) return OptionMarker.Correct
        return null
    }

    /** 自动下一题目标:循环扫描第一个 "unanswered";全答 → min(after+1, size-1);size==0 → 0。 */
    fun nextIndex(after: Int, states: List<String>): Int {
        if (states.isEmpty()) return 0
        var i = (after + 1) % states.size
        while (i != after) {
            if (states[i] == STATE_UNANSWERED) return i
            i = (i + 1) % states.size
        }
        return minOf(after + 1, states.size - 1)
    }

    /** 字母列表 → 上游 test_ans("key1,key3," 尾逗号;归一 A-D 排序去重)。 */
    fun lettersToKeys(letters: List<String>): String {
        val normalized = letters.distinct().sortedBy { listOf("A", "B", "C", "D").indexOf(it) }
        return normalized.joinToString("") { answerKey(it) ?: "" }
    }

    private fun answerKey(letter: String): String? = when (letter) {
        "A" -> "key1,"
        "B" -> "key2,"
        "C" -> "key3,"
        "D" -> "key4,"
        else -> null
    }

    /** 上游 test_ans("key3,key1,key3,unknown,")→ 字母(去重 A-D 排序);空 → []。 */
    fun keysToLetters(testAns: String): List<String> {
        return testAns.split(",")
            .mapNotNull { key -> when (key) {
                "key1" -> "A"; "key2" -> "B"; "key3" -> "C"; "key4" -> "D"; else -> null
            } }
            .distinct()
            .sortedBy { listOf("A", "B", "C", "D").indexOf(it) }
    }

    /** 答题卡 section tab 短标签:截断到第一个 "("(JS split 语义:以 "(" 开头 → "")。 */
    fun sectionTabLabel(title: String): String = title.split("(", limit = 2).first()
}
