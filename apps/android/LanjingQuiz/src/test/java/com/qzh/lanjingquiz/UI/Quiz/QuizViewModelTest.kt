package com.qzh.lanjingquiz.UI.Quiz

import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.Domain.CookieCloudSync
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Fixtures
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.EnterExamResult
import com.qzh.lanjingquiz.Network.ExamDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class QuizViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    private val exam = ExamDto(
        id = 111, name = "测试试卷", styleName = "机考题库", wfs = 1,
    )

    private fun makeApi(): FakeApi = FakeApi().apply {
        enterExamResult = EnterExamResult("ER1", "E1", "u1")
        examHtml = Fixtures.quizExamHtml
        questionBatch = Fixtures.quizQuestionBatch
    }

    private fun makeState(api: FakeApi = makeApi()): AppState {
        val secure = InMemorySecureStore()
        val settings = InMemorySettingsStore()
        return AppState(api, settings, CookieCloudSync(api, PrefsCookieStore(secure), secure, settings))
    }

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    /** runCurrent 而非 advanceUntilIdle:计时器按虚拟时间推进,全量推进会把 60s 倒计时跑完。 */
    private fun TestScope.startQuiz(api: FakeApi, appState: AppState): QuizViewModel {
        val vm = QuizViewModel(api, appState)
        vm.start(exam)
        runCurrent()
        return vm
    }

    @Test fun `enterExam populates questions states and current page`() = runTest(dispatcher) {
        val api = makeApi()
        val appState = makeState(api)
        val vm = startQuiz(api, appState)

        assertEquals(1, api.enterExamCalls)
        assertTrue(api.lastEnterIsNew)   // wfs==1 → 新卷流程
        assertEquals(listOf("q1", "q2", "q3", "q4"), vm.questions.value.map { it.id })
        assertEquals(4, vm.states.value.size)
        assertEquals("unanswered", vm.states.value[0].state)
        assertEquals(0, vm.page.value)                       // 第一未答题
        assertEquals(listOf(null, "科技常识", "逻辑推理"), vm.sectionTabs.value)
        assertTrue(vm.answers.value.isEmpty())
    }

    @Test fun `single correct tap submits and updates state`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.tapOption("A")
        advanceUntilIdle()
        assertEquals("right", vm.states.value[0].state)
        assertEquals(listOf("A"), vm.answers.value["q1"])
        assertEquals(listOf(Triple("q1", "key1,", true)), api.submittedAnswers)
        assertEquals(QuizViewModel.TimerMode.Paused, vm.timerMode.value)
        assertEquals("01:00", vm.timer.value)
    }

    @Test fun `single wrong tap submits correct=false and state error`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.tapOption("B")
        advanceUntilIdle()
        assertEquals("error", vm.states.value[0].state)
        assertEquals(listOf(Triple("q1", "key2,", false)), api.submittedAnswers)
    }

    @Test fun `multi toggles pending without submit until confirmed`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.goTo(2)
        advanceUntilIdle()
        vm.tapOption("A")
        vm.tapOption("C")
        assertEquals(0, api.submitAnswerCalls)
        assertEquals(setOf("A", "C"), vm.pendingMulti.value)

        vm.confirmSelection()
        advanceUntilIdle()
        assertEquals(listOf(Triple("q3", "key1,key3,", true)), api.submittedAnswers)
        assertEquals("right", vm.states.value[2].state)
        assertEquals(listOf("A", "C"), vm.answers.value["q3"])
        assertTrue(vm.pendingMulti.value.isEmpty())
    }

    @Test fun `multi wrong selection judged false`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.goTo(2)
        advanceUntilIdle()
        vm.tapOption("A")
        vm.tapOption("B")
        vm.confirmSelection()
        advanceUntilIdle()
        assertEquals(listOf(Triple("q3", "key1,key2,", false)), api.submittedAnswers)
        assertEquals("error", vm.states.value[2].state)
    }

    @Test fun `mark toggles optimistically and reports`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.toggleMark()
        advanceUntilIdle()
        assertTrue(vm.markedIds.value.contains("q1"))
        assertTrue(vm.states.value[0].marked)
        assertEquals(listOf("q1" to true), api.markCalls)

        vm.toggleMark()
        advanceUntilIdle()
        assertFalse(vm.markedIds.value.contains("q1"))
        assertEquals(listOf("q1" to true, "q1" to false), api.markCalls)
    }

    @Test fun `mark failure rolls back`() = runTest(dispatcher) {
        val api = makeApi()
        api.markError = ApiException(ApiException.UPSTREAM, "标记失败")
        val vm = startQuiz(api, makeState(api))

        vm.toggleMark()
        advanceUntilIdle()
        assertFalse(vm.markedIds.value.contains("q1"))
        assertFalse(vm.states.value[0].marked)
    }

    @Test fun `mark session expiry does not roll back and routes to login`() = runTest(dispatcher) {
        val api = makeApi()
        api.markError = ApiException.SESSION_EXPIRED_ERROR
        val appState = makeState(api)
        val vm = startQuiz(api, appState)

        vm.toggleMark()
        advanceUntilIdle()
        assertTrue(vm.markedIds.value.contains("q1"))
        assertEquals(Route.Login, appState.route.value)
    }

    @Test fun `auto-advance on correct after 1200ms`() = runTest(dispatcher) {
        val api = makeApi()
        val appState = makeState(api)
        appState.setAutoAdvance(true)
        val vm = startQuiz(api, appState)

        vm.tapOption("A")   // q1 答对
        runCurrent()        // 只执行当前队列,不推进虚拟时间(否则 1200ms 自动跳题会先跑完)
        assertEquals(0, vm.page.value)
        advanceTimeBy(1300)
        assertEquals(1, vm.page.value)
    }

    @Test fun `wrong answer never auto-advances`() = runTest(dispatcher) {
        val api = makeApi()
        val appState = makeState(api)
        appState.setAutoAdvance(true)
        val vm = startQuiz(api, appState)

        vm.tapOption("B")
        advanceUntilIdle()
        advanceTimeBy(1300)
        assertEquals(0, vm.page.value)
    }

    @Test fun `manual navigation cancels pending auto-advance`() = runTest(dispatcher) {
        val api = makeApi()
        val appState = makeState(api)
        appState.setAutoAdvance(true)
        val vm = startQuiz(api, appState)

        vm.tapOption("A")
        advanceTimeBy(600)
        vm.goTo(1)              // 手动导航取消待执行
        advanceTimeBy(1300)
        assertEquals(1, vm.page.value)   // 未再跳到第 3 题
    }

    @Test fun `timer counts down 60s and expires`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        assertEquals("01:00", vm.timer.value)
        assertEquals(QuizViewModel.TimerMode.Active, vm.timerMode.value)
        advanceTimeBy(60_000)
        runCurrent()   // 边界时刻的任务(第 60 个 tick)在 advanceTimeBy 严格小于处不执行
        assertEquals("00:00", vm.timer.value)
        assertEquals(QuizViewModel.TimerMode.Expired, vm.timerMode.value)
    }

    @Test fun `timer runID prevents stale ticks`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.goTo(1)
        advanceTimeBy(1000)
        runCurrent()   // 边界 tick
        assertEquals("00:59", vm.timer.value)
        vm.goTo(2)               // 旧 run 已被取消;若旧 tick 泄漏,新计时会少 1 秒
        advanceTimeBy(1000)
        runCurrent()
        assertEquals("00:59", vm.timer.value)
    }

    @Test fun `answered question pauses timer`() = runTest(dispatcher) {
        val api = makeApi()
        val vm = startQuiz(api, makeState(api))

        vm.tapOption("B")
        advanceUntilIdle()
        assertEquals("01:00", vm.timer.value)
        assertEquals(QuizViewModel.TimerMode.Paused, vm.timerMode.value)
        advanceTimeBy(5000)
        assertEquals("01:00", vm.timer.value)
    }

    @Test fun `submitConfirmed guards re-entrancy`() = runTest(dispatcher) {
        val api = makeApi()
        api.submitExamDelayMs = 100
        val vm = startQuiz(api, makeState(api))

        vm.submitConfirmed()
        vm.submitConfirmed()
        advanceUntilIdle()
        assertEquals(1, api.submitExamCalls)
        assertEquals("E1", api.lastSubmitExamInfoId)
        assertEquals("ER1", api.lastSubmitExamResultsId)
    }

    @Test fun `submit success routes to result with exam name`() = runTest(dispatcher) {
        val api = makeApi()
        val appState = makeState(api)
        val vm = startQuiz(api, appState)

        vm.submitConfirmed()
        advanceUntilIdle()
        val route = appState.route.value as? Route.Result
        assertTrue(route != null)
        assertEquals("88", route!!.result.score)
        assertEquals("72", route.result.beatRate)
        assertEquals("35", route.result.rank)
        assertEquals("测试试卷", route.examName)
    }

    @Test fun `submit failure shows notice and stays in quiz`() = runTest(dispatcher) {
        val api = makeApi()
        api.submitExamError = ApiException(ApiException.UPSTREAM, "服务器繁忙")
        val appState = makeState(api)
        appState.navigateTo(Route.Quiz(exam))
        val vm = startQuiz(api, appState)

        vm.submitConfirmed()
        advanceUntilIdle()
        assertEquals("服务器繁忙", appState.notice.value)
        assertTrue(appState.route.value is Route.Quiz)
        assertFalse(vm.isSubmitting.value)
    }

    @Test fun `session expiry during enter routes to login`() = runTest(dispatcher) {
        val api = makeApi()
        api.enterExamError = ApiException.SESSION_EXPIRED_ERROR
        val appState = makeState(api)
        val vm = QuizViewModel(api, appState)

        vm.start(exam)
        advanceUntilIdle()
        assertEquals(Route.Login, appState.route.value)
        assertEquals("登录已过期，请重新登录", appState.notice.value)
    }

    @Test fun `enter failure shows error message for retry`() = runTest(dispatcher) {
        val api = makeApi()
        api.enterExamError = ApiException(ApiException.UPSTREAM, "进入考试失败")
        val appState = makeState(api)
        val vm = QuizViewModel(api, appState)

        vm.start(exam)
        advanceUntilIdle()
        assertEquals("进入考试失败", vm.errorMessage.value)
        assertTrue(vm.questions.value.isEmpty())

        // 重试成功后恢复
        api.enterExamError = null
        vm.retry()
        advanceUntilIdle()
        assertEquals(4, vm.questions.value.size)
        assertNull(vm.errorMessage.value)
    }

    @Test fun `resume exam wfs=0 enters without new-paper dance`() = runTest(dispatcher) {
        val api = makeApi()
        api.enterExamResult = EnterExamResult("ER1", "E1", "u1")
        val resumeExam = exam.copy(wfs = 0)
        val vm = QuizViewModel(api, makeState(api))
        vm.start(resumeExam)
        advanceUntilIdle()
        assertFalse(api.lastEnterIsNew)
    }
}
