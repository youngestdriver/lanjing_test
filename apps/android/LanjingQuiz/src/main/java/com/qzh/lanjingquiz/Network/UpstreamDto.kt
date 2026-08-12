package com.qzh.lanjingquiz.Network

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonPrimitive

@Serializable(with = StringValue.Serializer::class)
data class StringValue(val value: String) {
    object Serializer : KSerializer<StringValue> {
        override val descriptor: SerialDescriptor =
            PrimitiveSerialDescriptor("StringValue", PrimitiveKind.STRING)
        override fun serialize(encoder: Encoder, value: StringValue) = encoder.encodeString(value.value)
        override fun deserialize(decoder: Decoder): StringValue {
            val json = decoder as? JsonDecoder ?: error("StringValue only works with JSON")
            val el = json.decodeJsonElement()
            return StringValue(when (el) {
                // 容忍 string/int/double;null → ""
                is JsonPrimitive -> if (el.isString) el.content else if (el.content == "null") "" else el.content
                else -> ""
            })
        }
    }
}

@Serializable
data class LoginResponse(val success: Boolean, val desc: String? = null)

@Serializable
data class ExamListResponse(
    val success: Boolean,
    val desc: String? = null,
    @SerialName("bizContent") val biz: ExamListBiz? = null,
)

@Serializable
data class ExamListBiz(
    val total: Int = 0,
    val styles: List<StyleDto> = emptyList(),
    @SerialName("examInfoModelList") val exams: List<ExamDto> = emptyList(),
)

@Serializable
data class StyleDto(val id: String = "", val name: String = "")

@Serializable
data class ExamDto(
    val id: String = "",
    @SerialName("examName") val name: String = "",
    @SerialName("examStyle") val examStyle: String = "",
    @SerialName("examStyleName") val styleName: String = "",
    @SerialName("practiceMode") val practiceMode: String = "",
    @SerialName("examMode") val examMode: String = "",
    @SerialName("examTime") val examTime: String = "",
    @SerialName("paperInfoId") val paperInfoId: String = "",
    @SerialName("examTimesNum") val examTimesNum: String = "",
    @SerialName("examTimesRestrict") val examTimesRestrict: String = "",
    val paid: Boolean = false,
    @SerialName("examTimeRestrict") val timeRestrict: String = "",
    val wfs: String = "",          // "1" 新卷
    @SerialName("timeLeft") val timeLeft: String = "",
)

@Serializable
data class QuestionDto(
    @SerialName("_id") val id: String = "",
    val question: String = "",
    @SerialName("parent_info") val parentInfo: String? = null,
    @SerialName("answer1") val answer1: String = "",
    @SerialName("answer2") val answer2: String = "",
    @SerialName("answer3") val answer3: String = "",
    @SerialName("answer4") val answer4: String = "",
    @SerialName("key1") val key1: StringValue? = null,
    @SerialName("key2") val key2: StringValue? = null,
    @SerialName("key3") val key3: StringValue? = null,
    @SerialName("key4") val key4: StringValue? = null,
    @SerialName("test_ans") val testAns: String = "",
    @SerialName("test_ans_right") val testAnsRight: String = "",
    val analysis: String = "",
    @SerialName("_isMulti") val isMulti: Boolean = false,
) {
    fun optionTexts(): List<String> = listOf(answer1, answer2, answer3, answer4)
}

/** /exam/start_exam_queue 与 /exam/check_queue_status 的响应。 */
@Serializable
data class QueueResponse(
    val bizContent: QueueBiz? = null,
    val code: StringValue? = null,
)

@Serializable
data class QueueBiz(val isOk: Boolean = false)
