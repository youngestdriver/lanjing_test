package com.qzh.lanjingquiz.Network

import com.qzh.lanjingquiz.Support.FormEncoder
import com.qzh.lanjingquiz.Support.Hashers
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

class ApiException(val code: Int, override val message: String) : Exception(message) {
    companion object {
        const val SESSION_EXPIRED = 401
        const val NOT_LOGGED_IN = 4011
        const val INVALID_RESPONSE = 5000
        const val UPSTREAM = 5001
        const val NETWORK = 5002
        val SESSION_EXPIRED_ERROR = ApiException(SESSION_EXPIRED, "登录已过期，请重新登录")
    }
}

data class ExamListResult(val total: Int, val styles: List<StyleDto>, val exams: List<ExamDto>)
data class EnterExamResult(val examResultsId: String, val examInfoId: String, val uuid: String?)
data class ExamResult(val score: String, val beatRate: String, val rank: String)
data class QuestionBatchRequest(
    val examResultsId: String, val examInfoId: String,
    val testIds: List<String>, val uuids: List<String>, val combId: String? = null,
)

interface UpstreamApi {
    suspend fun warmUpJsSession()
    suspend fun login(phone: String, password: String)
    suspend fun examList(): ExamListResult
    suspend fun enterExam(examInfoId: String): EnterExamResult
    suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto>
    suspend fun submitAnswer(examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean)
    suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean)
    suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult
    suspend fun logout()
    fun hasSession(): Boolean
    fun clearSession()
    val cookieHeader: String
}

/**
 * apps/web/server.js 代理逻辑的忠实移植:浏览器头伪装、持久 cookie jar、
 * 会话过期三规则与全部上游流程(登录 → 考试列表 → 进卷 → 题目 → 作答 → 标记 → 交卷)。
 */
class ApiClient(
    private val http: OkHttpClient,
    private val cookieJar: PersistentCookieJar,
    private val baseUrl: String = DEFAULT_BASE_URL,
) : UpstreamApi {

    private val json = Json { ignoreUnknownKeys = true }
    private val formType = "application/x-www-form-urlencoded; charset=UTF-8".toMediaType()

    override val cookieHeader: String get() = cookieJar.headerStringForBase()
    override fun hasSession(): Boolean = cookieJar.hasSession()
    override fun clearSession() = cookieJar.clear()

    override suspend fun warmUpJsSession() = withContext(Dispatchers.IO) {
        if (cookieJar.hasCookie("JSESSIONID")) return@withContext
        request("/login/account/login/1", detectExpiry = false)
    }

    override suspend fun login(phone: String, password: String) = withContext(Dispatchers.IO) {
        val normalized = phone.filterNot { it.isWhitespace() }
        val body = FormEncoder.encode(linkedMapOf(
            "userName" to "$normalized@1",
            "userNameInput" to normalized,
            "password" to Hashers.sha256Hex(password),
            "passwordMD5" to Hashers.md5Hex(password),
            "companyId" to "1", "newCompanyId" to "1", "remember" to "false",
            "phoneAccount" to "", "authCode" to "", "captchaText" to "", "nextUrl" to "",
        ))
        val resp = request("/login/account/login", form = body, referer = "$baseUrl/exam")
        val parsed = runCatching { json.decodeFromString(LoginResponse.serializer(), resp) }
            .getOrElse { throw ApiException(ApiException.INVALID_RESPONSE, "服务器响应异常") }
        if (!parsed.success) throw ApiException(ApiException.UPSTREAM, parsed.desc ?: "登录失败")
    }

    override suspend fun examList(): ExamListResult = withContext(Dispatchers.IO) {
        val body = FormEncoder.encode(linkedMapOf(
            "examStyle" to "0", "timeSort" to "", "status" to "", "setProcess" to "-1",
            "page" to "1", "firstVisit" to "true", "name" to "", "rowCount" to "100", "participation" to "",
        ))
        val resp = request("/exam/current_exam_list", form = body, referer = "$baseUrl/exam")
        val parsed = runCatching { json.decodeFromString(ExamListResponse.serializer(), resp) }
            .getOrElse { throw ApiException(ApiException.INVALID_RESPONSE, "服务器响应异常") }
        if (!parsed.success) throw ApiException(ApiException.UPSTREAM, parsed.desc ?: "获取考试列表失败")
        val biz = parsed.biz ?: ExamListBiz()
        ExamListResult(biz.total, biz.styles, biz.exams)
    }

    override suspend fun enterExam(examInfoId: String): EnterExamResult = withContext(Dispatchers.IO) {
        val referer = "$baseUrl/exam/before_answer_notice/$examInfoId"
        // 新卷步骤 0:enter_exam,跟随重定向(手动,规则 1 生效)
        request("/exam/enter_exam/1/$examInfoId")
        // 步骤 1:faceCheckCondition
        request("/exam/faceCheckCondition",
            form = FormEncoder.encode(mapOf("examInfoId" to examInfoId)), referer = referer)
        // 步骤 2:start_exam_queue;成功 = bizContent.isOk == true 或 code == "60011"
        val queueResp = request("/exam/start_exam_queue",
            form = FormEncoder.encode(mapOf("examId" to examInfoId)), referer = referer)
        val queue = runCatching { json.decodeFromString(QueueResponse.serializer(), queueResp) }.getOrNull()
        val queueOk = queue?.bizContent?.isOk == true || queue?.code?.value == "60011"
        // 步骤 3:未就绪则轮询 check_queue_status ≤30 次 × 2s(解码失败视为未就绪)
        if (!queueOk) {
            poll@ for (i in 0 until 30) {
                val poll = request("/exam/check_queue_status",
                    form = FormEncoder.encode(mapOf("examId" to examInfoId)), referer = referer)
                val status = runCatching { json.decodeFromString(QueueResponse.serializer(), poll) }.getOrNull()
                if (status?.bizContent?.isOk == true) break@poll
                delay(2000)
            }
        }
        // 步骤 4:轮询 test_complete 至 body(trim+小写)== "true"(≤30 次 × 2s)
        complete@ for (i in 0 until 30) {
            val complete = request("/exam/test_complete",
                form = FormEncoder.encode(mapOf("examId" to examInfoId)), referer = referer)
            if (complete.trim().lowercase() == "true") break@complete
            delay(2000)
        }
        // 步骤 5:GET exam_start,解析三个 JS 变量(卡片/分区/状态解析在 Task 3 ExamHtmlParser)
        val start = request("/exam/exam_start/$examInfoId", referer = referer)
        parseEnterResult(start, examInfoId)
    }

    override suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto> = withContext(Dispatchers.IO) {
        val referer = "$baseUrl/exam/exam_start/${req.examInfoId}"
        val uuids = if (req.uuids.size == req.testIds.size) req.uuids else req.testIds.map { "null" }
        val all = mutableListOf<QuestionDto>()
        val unitCount = req.testIds.size / 50 + if (req.testIds.size % 50 == 0) 0 else 1
        for (unit in 0 until unitCount) {
            val from = unit * 50
            val to = minOf(from + 50, req.testIds.size)
            val chunk = req.testIds.subList(from, to)
            val uuidChunk = uuids.subList(from, minOf(to, uuids.size))
            val form = linkedMapOf(
                "examResultsId" to req.examResultsId,
                "examInfoId" to req.examInfoId,
                "testIds" to chunk.joinToString(","),
                "uuids" to uuidChunk.joinToString(","),
            )
            if (req.combId != null) form["combId"] = req.combId
            // 上游偶发坏包(资料分析卷实测);与 iOS 一致重试同一次读取 3 次 × 3s;会话过期绝不重试
            var lastError: Throwable = ApiException(ApiException.INVALID_RESPONSE, "服务器响应异常")
            var fetched = false
            for (attempt in 1..3) {
                try {
                    val resp = request("/exam/get_question_info/",
                        form = FormEncoder.encode(form), referer = referer)
                    val dtos = runCatching { json.decodeFromString<List<QuestionDto>>(resp) }
                        .getOrElse { throw ApiException(ApiException.INVALID_RESPONSE, describeBatchFailure(unit, unitCount, chunk, resp)) }
                    all.addAll(dtos)
                    fetched = true
                    break
                } catch (e: ApiException) {
                    if (e.code == ApiException.SESSION_EXPIRED) throw e
                    lastError = e
                } catch (e: IOException) {
                    lastError = e
                }
                if (attempt < 3) delay(3000)
            }
            if (!fetched) {
                throw ApiException(ApiException.INVALID_RESPONSE, "重试 2 次后仍失败；${lastError.message}")
            }
        }
        all
    }

    override suspend fun submitAnswer(examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean) =
        withContext(Dispatchers.IO) {
            val list = buildJsonArray {
                add(buildJsonObject {
                    put("exam_results_id", examResultsId)
                    put("test_id", testId)
                    put("test_ans", testAns)
                    put("exam_info_id", examInfoId)
                    put("correct", correct)
                })
            }
            val form = linkedMapOf(
                "examTestList" to json.encodeToString(JsonElement.serializer(), list),
                "timeStamp" to System.currentTimeMillis().toString(),
            )
            request("/exam/exam_start_ing_multi",
                form = FormEncoder.encode(form), referer = "$baseUrl/exam/exam_start/$examInfoId")
            Unit
        }

    override suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean) =
        withContext(Dispatchers.IO) {
            val form = linkedMapOf(
                "test_id" to testId,
                "exam_results_id" to examResultsId,
                "exam_info_id" to examInfoId,
                "isMark" to if (isMark) "1" else "0",
                "timeStamp" to System.currentTimeMillis().toString(),
            )
            request("/exam/exam_question_mark",
                form = FormEncoder.encode(form), referer = "$baseUrl/exam/exam_start/$examInfoId")
            Unit
        }

    override suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult = withContext(Dispatchers.IO) {
        // 步骤 1:剩余时间(上游拼写错误 remian,保持)
        request("/exam/get_remian_time",
            form = FormEncoder.encode(mapOf("examResultId" to examResultsId)))
        // 步骤 2:结束考试 → 结果页
        val path = "/exam/exam_ending?examInfoId=$examInfoId&examResultsId=$examResultsId&isForce=0&switchScreen=0&noOpsAutoCommit=0"
        val end = request(path, referer = "$baseUrl/exam/exam_start/$examInfoId")
        // 非结果页(如仍在考试页)不得按完成提交解析
        if (!end.contains("class=\"score\"", ignoreCase = true)) {
            throw ApiException(ApiException.UPSTREAM, "考试未能结束，请刷新后重试")
        }
        parseExamResult(end)
    }

    override suspend fun logout() = withContext(Dispatchers.IO) {
        // best-effort 上游注销,失败也清本地;不触发过期检测
        if (hasSession()) {
            try {
                request("/login/public/logout", form = "",
                    referer = "$baseUrl/exam/pc/home/", detectExpiry = false)
            } catch (e: Exception) { /* 吞掉一切错误 */ }
        }
        clearSession()
    }

    /** 统一请求入口:请求头/表单编码/过期三规则/错误映射全部在此。 */
    private fun request(
        path: String,
        form: String? = null,
        referer: String = "$baseUrl/exam",
        detectExpiry: Boolean = true,
    ): String {
        val rb = form?.toRequestBody(formType)
        val isGet = form == null
        try {
            var response = http.newCall(buildRequest(baseUrl + path, rb, referer, isGet)).execute()
            // OkHttp 重定向已关闭(followRedirects(false));手动跟随一次,让过期规则 1 生效
            if (response.code in 300..399) {
                val location = response.header("Location")
                if (location != null) {
                    val target = resolveRedirect(baseUrl, location)
                    if (detectExpiry && target.contains("/login/account/login")) {
                        response.close()
                        clearSession()
                        throw ApiException.SESSION_EXPIRED_ERROR
                    }
                    response.close()
                    response = http.newCall(buildRequest(target, rb, referer, isGet)).execute()
                }
            }
            return response.use { resp ->
                val body = resp.body?.string().orEmpty()
                if (detectExpiry && detectSessionExpiry(resp.code, body)) {
                    clearSession()
                    throw ApiException.SESSION_EXPIRED_ERROR
                }
                if (resp.code !in 200..299) {
                    throw ApiException(ApiException.UPSTREAM, "服务器响应异常")
                }
                body
            }
        } catch (e: ApiException) {
            throw e
        } catch (e: IOException) {
            throw ApiException(ApiException.NETWORK, "网络错误：${e.message}")
        }
    }

    private fun buildRequest(url: String, body: RequestBody?, referer: String, isGet: Boolean): Request {
        val builder = Request.Builder().url(url)
            .header("User-Agent", USER_AGENT)
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Origin", baseUrl)
            .header("Referer", referer)
            .header("Accept", "application/json, text/javascript, */*; q=0.01")
            .header("sec-ch-ua", "\"Microsoft Edge\";v=\"149\", \"Chromium\";v=\"149\", \"Not)A;Brand\";v=\"24\"")
            .header("sec-ch-ua-mobile", "?0")
            .header("sec-ch-ua-platform", "\"Windows\"")
        return if (isGet) builder.get().build()
        else builder.post(body ?: "".toRequestBody(formType)).build()
    }

    private fun resolveRedirect(base: String, location: String): String =
        if (location.startsWith("http://") || location.startsWith("https://")) location
        else base + location

    /** 规则 2/3;规则 1(重定向目标含 /login/account/login)在 request() 内先行检查。 */
    internal fun detectSessionExpiry(status: Int, body: String): Boolean {
        val lc = body.lowercase()
        if (lc.contains("/login/account/login") && lc.contains("<!doctype")) return true
        return Regex("\"onlineStatus\"\\s*:\\s*\"?0\"?").containsMatchIn(body)
    }

    /** 仅解析 exam_start HTML 的三个 JS 变量;完整卡片/分区/状态解析属 Task 3 ExamHtmlParser。 */
    private fun parseEnterResult(html: String, fallbackExamInfoId: String): EnterExamResult {
        val resultsId = extractVar("exam_results_id", html)
        val infoId = extractVar("exam_info_id", html) ?: fallbackExamInfoId
        val uuid = extractVar("uuId", html)
        if (resultsId == null) throw ApiException(ApiException.UPSTREAM, "进入考试失败")
        return EnterExamResult(resultsId, infoId, uuid)
    }

    private fun extractVar(name: String, html: String): String? =
        Regex("""var\s+$name\s*=\s*['"]([^'"]+)['"]""").find(html)?.groupValues?.get(1)

    private fun describeBatchFailure(batchIndex: Int, batchCount: Int, testIds: List<String>, responseText: String): String {
        val parts = mutableListOf("第 ${batchIndex + 1}/$batchCount 批（${testIds.size} 题）响应无法解析")
        parts.add("涉及题目：${testIds.joinToString("、")}")
        val snippet = responseText.replace("\n", " ").take(300)
        parts.add("上游响应：$snippet")
        return parts.joinToString("；")
    }

    private fun parseExamResult(html: String): ExamResult {
        // 结果页正则(spec §3.1):class="score"(兜底 "0");exam-result-percentage 第一个 = beatRate,第二个 = rank
        val score = Regex("""class="score"[^>]*>\s*([\d.]+)\s*<""").find(html)?.groupValues?.get(1) ?: "0"
        val pcts = Regex("""exam-result-percentage[^>]*>\s*(\d+)""").findAll(html).map { it.groupValues[1] }.toList()
        val beatRate = pcts.getOrNull(0) ?: "?"
        val rank = pcts.getOrNull(1) ?: pcts.getOrNull(0) ?: "?"
        return ExamResult(score, beatRate, rank)
    }

    companion object {
        const val DEFAULT_BASE_URL = "https://test.lanjingweike.com"
        const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0"
    }
}
