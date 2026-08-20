package com.qzh.lanjingquiz

import com.qzh.lanjingquiz.Network.TestConfig
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

/**
 * 进程内 mock 上游(复刻 spec §3.1 全部考试路由 + wfs 语义),供 ExamFlowUiTest 全程封闭运行。
 * 与 iOS MockUpstreamServer.swift 同目标:不触真实上游;记录已提交答案与标记供断言。
 *
 * wfs 语义:新卷(wfs=1)走 enter_exam → faceCheckCondition → start_exam_queue → test_complete →
 * exam_start 完整队列;继续(wfs=0)直取 exam_start,无队列调用。
 */
class MockUpstreamServer {

    private val server = MockWebServer()

    /** testId → test_ans(已提交答案记录,供测试断言)。 */
    val submittedAnswers = ConcurrentHashMap<String, String>()

    /** testId → isMark(标记记录,供测试断言)。 */
    val marks = ConcurrentHashMap<String, Boolean>()

    /** 曾到达的请求(方法 + 路径,供流程断言)。 */
    val seenRequests = ConcurrentHashMap.newKeySet<String>()

    fun start(): MockUpstreamServer {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path?.substringBefore('?') ?: ""
                seenRequests.add("${request.method} $path")
                return route(request, path)
            }
        }
        server.start()
        return this
    }

    fun baseUrl(): String = server.url("/").toString().trimEnd('/')

    fun shutdown() {
        server.shutdown()
    }

    private fun route(request: RecordedRequest, path: String): MockResponse {
        return when {
            request.method == "GET" && path == "/login/account/login/1" ->
                json(200, "<html><head><title>login</title></head><body>login page</body></html>",
                    extraHeaders = "Set-Cookie: JSESSIONID=js; Path=/")
            request.method == "POST" && path == "/login/account/login" ->
                json(200, """{"success":true}""",
                    extraHeaders = "Set-Cookie: sessionId=s123; Path=/")
            request.method == "POST" && path == "/exam/current_exam_list" ->
                json(200, EXAM_LIST_JSON)
            request.method == "GET" && path.startsWith("/exam/enter_exam/1/") ->
                json(200, "")
            request.method == "POST" && path == "/exam/faceCheckCondition" ->
                json(200, """{}""")
            request.method == "POST" && path == "/exam/start_exam_queue" ->
                json(200, """{"bizContent":{"isOk":true}}""")
            request.method == "POST" && path == "/exam/check_queue_status" ->
                json(200, """{"bizContent":{"isOk":true}}""")
            request.method == "POST" && path == "/exam/test_complete" ->
                json(200, "true")
            request.method == "GET" && path.startsWith("/exam/exam_start/") ->
                json(200, EXAM_START_HTML)
            request.method == "POST" && path == "/exam/get_question_info/" ->
                json(200, questionBatch(request))
            request.method == "POST" && path == "/exam/exam_start_ing_multi" -> {
                recordAnswer(request)
                json(200, """{"success":true}""")
            }
            request.method == "POST" && path == "/exam/exam_question_mark" -> {
                recordMark(request)
                json(200, """{"success":true}""")
            }
            request.method == "POST" && path == "/exam/get_remian_time" ->
                json(200, """{}""")
            request.method == "GET" && path == "/exam/exam_ending" ->
                json(200, EXAM_ENDING_HTML)
            request.method == "POST" && path == "/login/public/logout" ->
                json(200, """{"success":true}""")
            else -> MockResponse().setResponseCode(404).setBody("not found")
        }
    }

    private fun json(status: Int, body: String, extraHeaders: String = ""): MockResponse {
        val r = MockResponse().setResponseCode(status).setBody(body)
        if (extraHeaders.isNotEmpty()) r.addHeader(extraHeaders.trim())
        return r
    }

    /** 记录 exam_start_ing_multi 的提交(testId → test_ans)。 */
    private fun recordAnswer(request: RecordedRequest) {
        val form = decodeForm(request.body.readUtf8())
        val examTestList = form["examTestList"] ?: return
        runCatching {
            val arr = Json.parseToJsonElement(examTestList).jsonArray
            for (item in arr) {
                val obj = item.jsonObject
                val testId = obj["test_id"]?.jsonPrimitive?.content ?: continue
                val testAns = obj["test_ans"]?.jsonPrimitive?.content ?: continue
                submittedAnswers[testId] = testAns
            }
        }
    }

    /** 记录 exam_question_mark 的标记(testId → isMark)。 */
    private fun recordMark(request: RecordedRequest) {
        val form = decodeForm(request.body.readUtf8())
        val testId = form["test_id"] ?: return
        marks[testId] = form["isMark"] == "1"
    }

    private fun decodeForm(body: String): Map<String, String> =
        body.split("&").mapNotNull { pair ->
            val (k, v) = pair.split("=", limit = 2).let { it[0] to it.getOrElse(1) { "" } }
            URLDecoder.decode(k, Charsets.UTF_8.name()) to URLDecoder.decode(v, Charsets.UTF_8.name())
        }.toMap()

    /** 2 场考试:111 新卷(wfs=1)、222 进行中(wfs=0),单 style 组"机考题库"。 */
    private companion object {
        const val EXAM_LIST_JSON = """
        {
          "success": true,
          "bizContent": {
            "total": 2,
            "styles": [{"id": "1052372", "name": "机考题库"}],
            "examInfoModelList": [
              {"id": 111, "examName": "【言语理解（二）】机考题库", "examStyle": "1052372", "examStyleName": "机考题库", "practiceMode": 2, "examMode": "", "examTime": 60, "wfs": 1, "timeLeft": null},
              {"id": 222, "examName": "【数字运算（一）】机考题库", "examStyle": "1052372", "examStyleName": "机考题库", "practiceMode": 2, "examMode": "", "examTime": 60, "wfs": 0, "timeLeft": null}
            ]
          }
        }
        """

        /**
         * 答题卡 HTML 夹具:2 个 section、4 张卡(exam_results_id=ER1、exam_info_id=EI1);
         * 状态:q1 未答 / q2 right / q3 未答 / q4 error(一 right 一 error 两 unanswered)。
         * 题目顺序对应:q1 单选 key1、q2 单选 key3、q3 多选 key1+key3、q4 无答案全 0
         * (与 brief 的四题集合一致;顺序按 UI 流程编排 —— 第 1 题点 B 判错、跳第 3 题做多选)。
         */
        val EXAM_START_HTML = """
        <!DOCTYPE html>
        <html>
        <head><script>
        var exam_results_id = 'ER1';
        var exam_info_id = 'EI1';
        </script></head>
        <body>
        <div class="exam-content">
          <div class="card-content-title">科技常识</div>
          <div class="card-content-list">
            <a href="#1"><div class="question_cbox"><span>1</span><span questionsId="q1" uuId="u1"></span></div></a>
            <a href="#2"><div class="question_cbox right"><span>2</span><span questionsId="q2" uuId="u2"></span></div></a>
          </div>
          <div class="card-content-title">逻辑推理</div>
          <div class="card-content-list">
            <a href="#3"><div class="question_cbox"><span>3</span><span questionsId="q3" uuId="u3"></span></div></a>
            <a href="#4"><div class="question_cbox error"><span>4</span><span questionsId="q4" uuId="u4"></span></div></a>
          </div>
        </div>
        </body>
        </html>
        """.trimIndent()

        /** 结果页:class="score">88<、两个 exam-result-percentage(beatRate 72 / rank 35)。 */
        val EXAM_ENDING_HTML = """
        <!DOCTYPE html>
        <html><body>
        <div class="score">88</div>
        <span class="exam-result-percentage">72</span>
        <span class="exam-result-percentage">35</span>
        </body></html>
        """.trimIndent()

        fun questionBatch(request: RecordedRequest): String {
            // 按 testIds 顺序返回 4 题(与卡片一一对应)
            val dtos = listOf(
                dto("q1", "<p>题干1</p>", "1", "0", "0", "0", testAnsRight = "A"),
                dto("q2", "<p>题干2</p>", "0", "0", "1", "0", testAns = "key3,", testAnsRight = "C"),
                dto("q3", "<p>题干3</p>", "1", "0", "1", "0", testAnsRight = "A,C"),
                dto("q4", "<p>题干4</p>", "0", "0", "0", "0", testAnsRight = ""),
            )
            return "[${dtos.joinToString(",")}]"
        }

        fun dto(
            id: String,
            question: String,
            k1: String, k2: String, k3: String, k4: String,
            testAns: String = "",
            testAnsRight: String = "",
        ): String =
            """{"_id":"$id","question":"$question","answer1":"<p>选项A</p>","answer2":"<p>选项B</p>","answer3":"<p>选项C</p>","answer4":"<p>选项D</p>","key1":"$k1","key2":"$k2","key3":"$k3","key4":"$k4","test_ans":"$testAns","test_ans_right":"$testAnsRight","analysis":"<p>解析$id</p>"}"""
    }
}
