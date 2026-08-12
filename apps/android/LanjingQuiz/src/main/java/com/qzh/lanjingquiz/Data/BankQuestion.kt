package com.qzh.lanjingquiz.Data

import com.qzh.lanjingquiz.Support.HtmlHelpers
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray

/**
 * 答案三态(iOS BankQuestion.Answer 移植):"A"(单选)/ ["A","C"](多选)/ null(无答案)。
 * 解码容错:字符串 → Single(恰 1 字符,否则 None);数组 → Multi;null/缺失/其他 → None。
 * 编码:Single → 字符串(绝不一元素数组);Multi → 数组;None → null。
 */
@Serializable(with = AnswerShape.Serializer::class)
sealed interface AnswerShape {
    data class Single(val letter: String) : AnswerShape
    data class Multi(override val letters: List<String>) : AnswerShape
    data object None : AnswerShape

    /** 判分用字母列表;None → 空。 */
    val letters: List<String>
        get() = when (this) {
            is Single -> listOf(letter)
            is Multi -> letters
            None -> emptyList()
        }

    object Serializer : KSerializer<AnswerShape> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("AnswerShape")

        override fun serialize(encoder: Encoder, value: AnswerShape) {
            val json = encoder as? JsonEncoder ?: error("AnswerShape only works with JSON")
            json.encodeJsonElement(when (value) {
                is Single -> JsonPrimitive(value.letter)
                is Multi -> buildJsonArray { value.letters.forEach { add(JsonPrimitive(it)) } }
                None -> JsonNull
            })
        }

        override fun deserialize(decoder: Decoder): AnswerShape {
            val json = decoder as? JsonDecoder ?: error("AnswerShape only works with JSON")
            return when (val el = json.decodeJsonElement()) {
                is JsonPrimitive ->
                    if (el.isString && el.content.length == 1) Single(el.content) else None
                is JsonArray ->
                    Multi(el.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content })
                else -> None
            }
        }
    }
}

/**
 * 一条练习题目(JSONL 一行;iOS BankQuestion 移植)。JSON 键逐字 spec §3.2:
 * _id/category/section/subCategory/question/stem/options/answer/analysis/
 * sourceExamName/round/collectedAt;options 恒 4 槽,空串 = 填空。
 * question/stem/analysis 的协议相对图片 src 在构造/读取路径统一归一化。
 */
@Serializable
data class BankQuestion(
    @SerialName("_id") val id: String,
    val category: String = "",
    val section: String = "",
    @SerialName("subCategory") val subCategory: String = "",
    val question: String = "",
    val stem: String? = null,
    val options: List<String> = emptyList(),
    val answer: AnswerShape? = null,
    val analysis: String? = null,
    @SerialName("sourceExamName") val sourceExamName: String? = null,
    val round: Int? = null,
    @SerialName("collectedAt") val collectedAt: String? = null,
)

/** 读取路径统一归一化(协议相对图片 src → https),与 iOS init(from:) 解码归一行为一致。 */
internal fun BankQuestion.normalized(): BankQuestion = copy(
    question = HtmlHelpers.normalizeImgSrcs(question) ?: question,
    stem = HtmlHelpers.normalizeImgSrcs(stem),
    analysis = HtmlHelpers.normalizeImgSrcs(analysis),
)
