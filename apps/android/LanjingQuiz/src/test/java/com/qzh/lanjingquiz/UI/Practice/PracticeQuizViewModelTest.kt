package com.qzh.lanjingquiz.UI.Practice

import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.FakePracticeProgressStore
import com.qzh.lanjingquiz.Data.FakePracticeSessionStore
import com.qzh.lanjingquiz.Data.InMemoryBankStorage
import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.Data.PracticeAnswer
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Domain.BankLogic
import com.qzh.lanjingquiz.Domain.CookieCloudSync
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
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

/** iOS PracticeBankViewModelTests 作答/持久化用例 + 洗牌(固定种子)用例移植。 */
@OptIn(ExperimentalCoroutinesApi::class)
class PracticeQuizViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    // 3 题成语辨析:q1 单选 B、q2 无答案、q3 多选 A+C
    private val quiz = listOf(
        question("q1", answer = AnswerShape.Single("B")),
        question("q2", answer = null),
        question("q3", answer = AnswerShape.Multi(listOf("A", "C"))),
    )

    private fun question(
        id: String,
        subCategory: String = "成语辨析",
        answer: AnswerShape? = AnswerShape.Single("B"),
        stem: String? = null,
    ): BankQuestion = BankQuestion(
        id = id, category = "言语理解", section = "逻辑填空", subCategory = subCategory,
        question = "<p>题干 $id</p>", stem = stem,
        options = listOf("<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"),
        answer = answer, analysis = null,
        sourceExamName = "【言语理解（二）】机考题库", round = null, collectedAt = null,
    )

    private fun makeVm(
        storage: InMemoryBankStorage = InMemoryBankStorage(),
        sessionStore: FakePracticeSessionStore = FakePracticeSessionStore(),
        progressStore: FakePracticeProgressStore = FakePracticeProgressStore(),
        settings: InMemorySettingsStore = InMemorySettingsStore(),
    ): PracticeQuizViewModel {
        val secure = InMemorySecureStore()
        val appState = AppState(FakeApi(), InMemorySettingsStore(), CookieCloudSync(FakeApi(), PrefsCookieStore(secure), secure, InMemorySettingsStore()))
        return PracticeQuizViewModel(
        appState = appState,
        storage = storage,
        sessionStore = sessionStore,
            progressStore = progressStore,
            settings = settings,
        )
    }

    /** start + 推进进度注册表加载。 */
    private fun TestScope.startQuiz(vm: PracticeQuizViewModel, questions: List<BankQuestion> = quiz) {
        vm.start(PracticeSession("言语理解", "成语辨析", questions))
        advanceUntilIdle()
    }

    // ---- 单选 ----

    @Test
    fun `single tap reveals grades immediately and records progress`() = runTest(dispatcher) {
        val sessionStore = FakePracticeSessionStore()
        val progressStore = FakePracticeProgressStore()
        val vm = makeVm(sessionStore = sessionStore, progressStore = progressStore)
        startQuiz(vm)

        vm.tapOption("A")   // q1 答案 B → 错
        val session = vm.session.value!!
        assertTrue(session.answers[0].revealed)
        assertEquals(false, session.answers[0].correct)
        assertEquals(listOf("A"), session.answers[0].selected)
        assertEquals(0, session.rightCount)
        assertEquals(1, session.wrongCount)
        assertEquals(1, session.answeredCount)

        // 第二次 tap 同题:已 reveal → 不变,进度不重复记录
        vm.tapOption("B")
        assertEquals(listOf("A"), vm.session.value!!.answers[0].selected)

        advanceUntilIdle()
        assertEquals(1, progressStore.saveCount)
        assertEquals(listOf("q1"), progressStore.stored?.get("言语理解/成语辨析")?.answeredIDs)
        // 会话持久化:初始 save(创建)+ tap save
        assertEquals(1, sessionStore.saveCount)
        assertEquals(listOf("A"), sessionStore.stored?.answers?.get(0)?.selected)
    }

    @Test
    fun `single correct tap grades right`() = runTest(dispatcher) {
        val vm = makeVm()
        startQuiz(vm)

        vm.tapOption("B")
        val session = vm.session.value!!
        assertEquals(true, session.answers[0].correct)
        assertEquals(1, session.rightCount)
        assertEquals(0, session.wrongCount)
    }

    // ---- 多选 ----

    @Test
    fun `multi pending not recorded until confirm`() = runTest(dispatcher) {
        val progressStore = FakePracticeProgressStore()
        val vm = makeVm(progressStore = progressStore)
        startQuiz(vm)

        vm.goTo(2)
        vm.tapOption("A")
        vm.tapOption("C")
        assertEquals(setOf("A", "C"), vm.pendingMulti.value)
        assertFalse(vm.session.value!!.answers[2].revealed)
        advanceUntilIdle()
        assertEquals(0, progressStore.saveCount)   // 未提交不记

        vm.confirmSelection()
        val session = vm.session.value!!
        assertTrue(session.answers[2].revealed)
        assertEquals(true, session.answers[2].correct)
        assertEquals(1, session.rightCount)
        advanceUntilIdle()
        assertEquals(1, progressStore.saveCount)
        assertEquals(listOf("q3"), progressStore.stored?.get("言语理解/成语辨析")?.answeredIDs)
    }

    @Test
    fun `multi wrong selection graded wrong on confirm`() = runTest(dispatcher) {
        val vm = makeVm()
        startQuiz(vm)

        vm.goTo(2)
        vm.tapOption("B")
        vm.confirmSelection()
        val session = vm.session.value!!
        assertEquals(false, session.answers[2].correct)
        assertEquals(1, session.wrongCount)
    }

    // ---- 无答案 ----

    @Test
    fun `ungradable tap reveals without verdict and counts answered only`() = runTest(dispatcher) {
        val progressStore = FakePracticeProgressStore()
        val vm = makeVm(progressStore = progressStore)
        startQuiz(vm)

        vm.tapOption("A")   // q1 单选错 → answered
        vm.nextQuestion()   // → q2 无答案
        vm.tapOption("A")
        val session = vm.session.value!!
        assertEquals(1, session.index)
        assertTrue(session.answers[1].revealed)
        assertNull(session.answers[1].correct)
        assertEquals(listOf("A"), session.answers[1].selected)
        assertEquals(2, session.answeredCount)
        assertEquals(0, session.rightCount)
        assertEquals(1, session.wrongCount)   // 无答案不计对错

        advanceUntilIdle()
        assertEquals(listOf("q1", "q2"), progressStore.stored?.get("言语理解/成语辨析")?.answeredIDs)
    }

    // ---- 导航与持久化 ----

    @Test
    fun `nextQuestion keeps per question state and clears file on finish`() = runTest(dispatcher) {
        val sessionStore = FakePracticeSessionStore()
        val vm = makeVm(sessionStore = sessionStore)
        startQuiz(vm)

        vm.tapOption("A")   // q1 错
        vm.nextQuestion()
        assertEquals(1, vm.page.value)
        assertEquals(listOf("A"), vm.session.value!!.answers[0].selected)  // 状态随题保留

        vm.tapOption("A")   // q2 无答案
        vm.nextQuestion()
        vm.tapOption("A")   // q3 多选 A+C
        vm.tapOption("C")
        vm.confirmSelection()
        vm.nextQuestion()   // 完成

        val session = vm.session.value!!
        assertTrue(session.isFinished)
        assertEquals(1, session.rightCount)
        assertEquals(1, session.wrongCount)
        // 完成即清文件(内存保留供 summary)
        advanceUntilIdle()
        assertEquals(1, sessionStore.clearCount)
        assertNull(sessionStore.stored)
        assertTrue(vm.session.value!!.isFinished)
    }

    @Test
    fun `goTo jumps and persists index`() = runTest(dispatcher) {
        val sessionStore = FakePracticeSessionStore()
        val vm = makeVm(sessionStore = sessionStore)
        startQuiz(vm)

        vm.tapOption("A")
        vm.nextQuestion()
        vm.goTo(0)
        assertEquals(0, vm.page.value)
        assertEquals(listOf("A"), vm.session.value!!.answers[0].selected)

        vm.goTo(2)
        vm.goTo(2)   // 同索引 no-op
        vm.goTo(99)  // 越界 no-op
        assertEquals(2, vm.page.value)
        advanceUntilIdle()
        assertEquals(2, sessionStore.stored?.index)
    }

    // ---- 恢复 ----

    @Test
    fun `resume loads shuffled archive without reshuffling and endSession clears file`() = runTest(dispatcher) {
        val sessionStore = FakePracticeSessionStore().apply {
            stored = PracticeSession(
                category = "言语理解", subCategory = "成语辨析",
                questions = listOf(quiz[1], quiz[0], quiz[2]),   // 乱序存档
                index = 1,
                answers = listOf(
                    PracticeAnswer(selected = listOf("B"), revealed = true, correct = false),
                    PracticeAnswer(), PracticeAnswer(),
                ),
            )
        }
        val vm = makeVm(sessionStore = sessionStore)

        vm.start(sessionStore.stored!!, resumed = true)
        advanceUntilIdle()

        assertTrue(vm.resumedFromDisk.value)
        assertEquals(listOf("q2", "q1", "q3"), vm.session.value!!.questions.map { it.id })  // 载入不复洗
        assertEquals(1, vm.page.value)
        assertEquals(1, vm.session.value!!.wrongCount)
        // 恢复不重复持久化,文件仍在(系统返回不清会话)
        assertEquals(0, sessionStore.saveCount)
        assertTrue(sessionStore.stored != null)

        vm.endSession()
        advanceUntilIdle()
        assertEquals(1, sessionStore.clearCount)
        assertNull(sessionStore.stored)
        assertFalse(vm.resumedFromDisk.value)
    }

    // ---- 随机顺序 ----

    @Test
    fun `shuffle rebuilds order with fixed seed keeping groups adjacent and answers by id`() = runTest(dispatcher) {
        val questions = listOf(
            question("q1", subCategory = "复合", answer = AnswerShape.Single("A"), stem = "材料1"),
            question("q2", subCategory = "复合", answer = AnswerShape.Single("B"), stem = "材料1"),
            question("q3", subCategory = "复合", answer = AnswerShape.Single("C"), stem = "材料2"),
            question("q4", subCategory = "复合", answer = AnswerShape.Single("D"), stem = "材料2"),
        )
        val storage = InMemoryBankStorage().apply { setCategory("资料分析", questions) }
        val settings = InMemorySettingsStore()
        val vm = makeVm(storage = storage, settings = settings)

        vm.start(PracticeSession("资料分析", "复合", questions))
        advanceUntilIdle()
        vm.setShuffle(true, seed = 42UL)

        val shuffled = vm.session.value!!.questions
        val ids = shuffled.map { it.id }
        // 固定种子 → 与 BankLogic 同种子计算结果一致(确定性)
        assertEquals(
            BankLogic.groupShuffleQuestions(questions, 42UL).map { it.id },
            ids,
        )
        // 同材料组合题保持相邻且组内顺序不变
        assertEquals(ids.indexOf("q1") + 1, ids.indexOf("q2"))
        assertEquals(ids.indexOf("q3") + 1, ids.indexOf("q4"))
        assertTrue(settings.getBoolean("practice.shuffle.资料分析", false))

        // 作答后切换回自然序:answers 按题目 ID 保留(非位置)
        vm.goTo(ids.indexOf("q1"))
        vm.tapOption("A")   // q1 对
        vm.setShuffle(false)
        assertEquals(listOf("q1", "q2", "q3", "q4"), vm.session.value!!.questions.map { it.id })
        val q1Answer = vm.session.value!!.answers[0]
        assertTrue(q1Answer.revealed)
        assertEquals(true, q1Answer.correct)
        assertEquals(listOf("A"), q1Answer.selected)
        assertFalse(settings.getBoolean("practice.shuffle.资料分析", false))
    }
}
