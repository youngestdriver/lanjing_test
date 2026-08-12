package com.qzh.lanjingquiz

import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.EnterExamResult
import com.qzh.lanjingquiz.Network.ExamListResult
import com.qzh.lanjingquiz.Network.ExamResult
import com.qzh.lanjingquiz.Network.QuestionBatchRequest
import com.qzh.lanjingquiz.Network.QuestionDto
import com.qzh.lanjingquiz.Network.UpstreamApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay

/** JVM 单测用假上游(跨任务复用,与 UpstreamApi 接口逐方法对齐)。 */
class FakeApi : UpstreamApi {
    var session: Boolean = false
    var loginError: ApiException? = null
    var logoutCalls = 0
    var loginCalls = 0
    var lastLoginPhone: String? = null
    var lastLoginPassword: String? = null

    // ---- 考试模块可配置项(默认值对既有测试无影响) ----
    var enterExamResult = EnterExamResult("r1", "e1", "u1")
    /** exam_start HTML(examStartHtml 返回)。 */
    var examHtml: String = ""
    var questionBatch: List<QuestionDto> = emptyList()
    var enterExamError: ApiException? = null
    var examHtmlError: ApiException? = null
    var fetchError: ApiException? = null
    var submitAnswerError: ApiException? = null
    var markError: ApiException? = null
    var submitExamError: ApiException? = null
    var submitExamDelayMs = 0L
    var submitExamResult = ExamResult("88", "72", "35")

    // ---- 练习/爬取(T5) ----
    var examListResult = ExamListResult(0, emptyList(), emptyList())
    var examListError: ApiException? = null
    /** 第 gateFromCall+1 次起 enterExam 挂起等待(确定性观察爬取中间进度)。 */
    var enterExamGate: CompletableDeferred<Unit>? = null
    var gateFromCall: Int = 0

    // ---- 调用记录 ----
    var enterExamCalls = 0
    var examListCalls = 0
    var lastEnterExamInfoId: String? = null
    var lastEnterIsNew: Boolean = true
    var examStartHtmlCalls = 0
    var fetchQuestionsCalls = 0
    var submitAnswerCalls = 0
    var submitExamCalls = 0
    var lastSubmitExamInfoId: String? = null
    var lastSubmitExamResultsId: String? = null
    val submittedAnswers = mutableListOf<Triple<String, String, Boolean>>()  // testId, testAns, correct
    val markCalls = mutableListOf<Pair<String, Boolean>>()  // testId, isMark

    override suspend fun warmUpJsSession() {}

    override suspend fun login(phone: String, password: String) {
        loginCalls++
        lastLoginPhone = phone
        lastLoginPassword = password
        loginError?.let { throw it }
        session = true
    }

    override suspend fun examList(): ExamListResult {
        examListCalls++
        examListError?.let { throw it }
        return examListResult
    }

    override suspend fun enterExam(examInfoId: String, isNew: Boolean): EnterExamResult {
        enterExamCalls++
        lastEnterExamInfoId = examInfoId
        lastEnterIsNew = isNew
        if (enterExamGate != null && enterExamCalls > gateFromCall) enterExamGate!!.await()
        enterExamError?.let { throw it }
        return enterExamResult
    }

    override suspend fun examStartHtml(examInfoId: String): String {
        examStartHtmlCalls++
        examHtmlError?.let { throw it }
        return examHtml
    }

    override suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto> {
        fetchQuestionsCalls++
        fetchError?.let { throw it }
        return questionBatch
    }

    override suspend fun submitAnswer(
        examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean,
    ) {
        submitAnswerCalls++
        submittedAnswers += Triple(testId, testAns, correct)
        submitAnswerError?.let { throw it }
    }

    override suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean) {
        markCalls += testId to isMark
        markError?.let { throw it }
    }

    override suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult {
        submitExamCalls++
        lastSubmitExamInfoId = examInfoId
        lastSubmitExamResultsId = examResultsId
        if (submitExamDelayMs > 0) delay(submitExamDelayMs)
        submitExamError?.let { throw it }
        return submitExamResult
    }

    override suspend fun logout() { logoutCalls++ }

    override fun hasSession(): Boolean = session
    override fun clearSession() { session = false }
    override val cookieHeader: String get() = ""
}
