package com.qzh.lanjingquiz

import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.EnterExamResult
import com.qzh.lanjingquiz.Network.ExamListResult
import com.qzh.lanjingquiz.Network.ExamResult
import com.qzh.lanjingquiz.Network.QuestionBatchRequest
import com.qzh.lanjingquiz.Network.QuestionDto
import com.qzh.lanjingquiz.Network.UpstreamApi

/** JVM 单测用假上游(跨任务复用,与 UpstreamApi 接口逐方法对齐)。 */
class FakeApi : UpstreamApi {
    var session: Boolean = false
    var loginError: ApiException? = null
    var logoutCalls = 0
    var loginCalls = 0
    var lastLoginPhone: String? = null
    var lastLoginPassword: String? = null

    override suspend fun warmUpJsSession() {}

    override suspend fun login(phone: String, password: String) {
        loginCalls++
        lastLoginPhone = phone
        lastLoginPassword = password
        loginError?.let { throw it }
        session = true
    }

    override suspend fun examList(): ExamListResult = ExamListResult(0, emptyList(), emptyList())

    override suspend fun enterExam(examInfoId: String): EnterExamResult =
        EnterExamResult("r1", examInfoId, null)

    override suspend fun fetchQuestions(req: QuestionBatchRequest): List<QuestionDto> = emptyList()

    override suspend fun submitAnswer(
        examResultsId: String, examInfoId: String, testId: String, testAns: String, correct: Boolean,
    ) {}

    override suspend fun markQuestion(testId: String, examResultsId: String, examInfoId: String, isMark: Boolean) {}

    override suspend fun submitExam(examInfoId: String, examResultsId: String): ExamResult =
        ExamResult("0", "?", "?")

    override suspend fun logout() { logoutCalls++ }

    override fun hasSession(): Boolean = session
    override fun clearSession() { session = false }
    override val cookieHeader: String get() = ""
}
