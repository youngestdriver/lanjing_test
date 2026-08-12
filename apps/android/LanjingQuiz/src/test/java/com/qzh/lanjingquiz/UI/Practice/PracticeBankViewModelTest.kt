package com.qzh.lanjingquiz.UI.Practice

import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankMeta
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.FakePracticeProgressStore
import com.qzh.lanjingquiz.Data.FakePracticeSessionStore
import com.qzh.lanjingquiz.Data.InMemoryBankStorage
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.Data.PracticeAnswer
import com.qzh.lanjingquiz.Data.PracticeProgress
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Domain.Crawler
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.Network.ExamListResult
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** iOS PracticeBankViewModelTests.swift 练习库用例移植(ensureBankReady/聚合/去重/删除/刷新/恢复)。 */
@OptIn(ExperimentalCoroutinesApi::class)
class PracticeBankViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    // ---- Fixtures ----

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

    private fun paper(id: Int, name: String): ExamDto =
        ExamDto(id = id, name = name, styleName = "机考题库", wfs = 1)

    private fun makeVm(
        api: FakeApi = FakeApi(),
        storage: InMemoryBankStorage = InMemoryBankStorage(),
        sessionStore: FakePracticeSessionStore = FakePracticeSessionStore(),
        progressStore: FakePracticeProgressStore = FakePracticeProgressStore(),
        appState: AppState = AppState(FakeApi(), InMemorySettingsStore()),
    ): PracticeBankViewModel = PracticeBankViewModel(
        api = api,
        storage = storage,
        sessionStore = sessionStore,
        progressStore = progressStore,
        settings = InMemorySettingsStore(),
        appState = appState,
        crawler = Crawler(api, storage),
    )

    // ---- ensureBankReady ----

    @Test
    fun `ensureBankReady populated bank is Ready without network`() = runTest(dispatcher) {
        val api = FakeApi()
        val storage = InMemoryBankStorage().apply {
            populated = true
            meta = BankMeta(version = 1, round = 3, counts = mapOf("言语理解" to 3))
        }
        val vm = makeVm(api, storage)

        vm.ensureBankReady()
        advanceUntilIdle()

        assertEquals(BankPhase.Ready, vm.phase.value)
        assertEquals(0, api.examListCalls)   // 不触网
        val categories = vm.categories.value
        assertEquals(listOf("言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"), categories.map { it.name })
        assertEquals(3, categories.first { it.name == "言语理解" }.count)
        assertEquals(0, categories.first { it.name == "言语理解" }.answered)
    }

    @Test
    fun `ensureBankReady without session is NeedsLogin`() = runTest(dispatcher) {
        val api = FakeApi().apply { session = false }
        val vm = makeVm(api)

        vm.ensureBankReady()
        advanceUntilIdle()

        assertEquals(BankPhase.NeedsLogin, vm.phase.value)
        assertEquals(0, api.examListCalls)
    }

    @Test
    fun `crawl shows Crawling progress then Failed on repeated enter failures`() = runTest(dispatcher) {
        val api = FakeApi().apply {
            session = true
            examListResult = ExamListResult(
                0, emptyList(),
                listOf(paper(1, "【言语理解（一）】机考题库"), paper(2, "【数字运算（二）】机考题库")),
            )
            examHtmlError = ApiException(ApiException.UPSTREAM, "boom")
        }
        val gate = CompletableDeferred<Unit>()
        api.enterExamGate = gate
        api.gateFromCall = 1   // 第 2 次进卷起挂起,确定性观察中间进度
        val vm = makeVm(api)

        vm.ensureBankReady()
        advanceUntilIdle()

        // paper1 进卷成功但取页失败(进度 1/2);paper2 挂在进卷 gate 上
        val phase = vm.phase.value
        assertTrue("expected Crawling, got $phase", phase is BankPhase.Crawling)
        assertEquals(1, (phase as BankPhase.Crawling).progress.current)
        assertEquals(2, phase.progress.total)
        assertEquals("【言语理解（一）】机考题库", phase.progress.paperName)
        assertEquals("enter", phase.progress.phase)

        gate.complete(Unit)
        advanceUntilIdle()

        // 2 卷全失败 → Failed(连败 < 3,增量爬全部尝试后统一报错)
        assertTrue(vm.phase.value is BankPhase.Failed)
        assertEquals(
            "2 份试卷爬取失败：【言语理解（一）】机考题库、【数字运算（二）】机考题库",
            (vm.phase.value as BankPhase.Failed).message,
        )
    }

    @Test
    fun `crawl list failure maps to Failed message`() = runTest(dispatcher) {
        val api = FakeApi().apply {
            session = true
            examListError = ApiException(ApiException.UPSTREAM, "网络错误：boom")
        }
        val vm = makeVm(api)

        vm.ensureBankReady()
        advanceUntilIdle()

        assertTrue(vm.phase.value is BankPhase.Failed)
        assertEquals("网络错误：boom", (vm.phase.value as BankPhase.Failed).message)
    }

    @Test
    fun `retry after failure re-runs crawl and reaches Ready`() = runTest(dispatcher) {
        val api = FakeApi().apply {
            session = true
            examListError = ApiException(ApiException.UPSTREAM, "网络错误：boom")
        }
        val vm = makeVm(api)

        vm.ensureBankReady()
        advanceUntilIdle()
        assertTrue(vm.phase.value is BankPhase.Failed)
        assertEquals(1, api.examListCalls)

        api.examListError = null   // 网络恢复
        vm.retry()
        advanceUntilIdle()

        // ensureBankReady 仅 Idle 才跑,retry 必须复位相位后重爬(否则重试是死路)
        assertEquals(2, api.examListCalls)
        assertEquals(BankPhase.Ready, vm.phase.value)
    }

    // ---- 进度注册表 ----

    @Test
    fun `answeredCount aggregates across subcategories by prefix`() = runTest(dispatcher) {
        val progressStore = FakePracticeProgressStore().apply {
            stored = mapOf(
                "言语理解/虚词辨析" to PracticeProgress(listOf("x1", "x2")),
                "数字运算/速算" to PracticeProgress(listOf("y1")),
            )
        }
        val storage = InMemoryBankStorage().apply {
            populated = true
            meta = BankMeta(version = 1, round = 1, counts = mapOf("言语理解" to 3))
        }
        val vm = makeVm(storage = storage, progressStore = progressStore)

        vm.ensureBankReady()
        advanceUntilIdle()

        vm.recordAnswered("言语理解", "成语辨析", "q1")
        advanceUntilIdle()

        assertEquals(1, vm.answeredCount("言语理解", "成语辨析"))
        assertEquals(3, vm.answeredCount("言语理解"))   // 本会话 1 + 预置虚词辨析 2
        assertEquals(1, vm.answeredCount("数字运算"))
        assertEquals(0, vm.answeredCount("逻辑推理"))
    }

    @Test
    fun `recordAnswered dedupes same question id`() = runTest(dispatcher) {
        val progressStore = FakePracticeProgressStore()
        val vm = makeVm(progressStore = progressStore)

        vm.recordAnswered("言语理解", "成语辨析", "q1")
        vm.recordAnswered("言语理解", "成语辨析", "q1")
        vm.recordAnswered("言语理解", "成语辨析", "q2")
        advanceUntilIdle()

        assertEquals(2, progressStore.saveCount)   // q1 第二次 tap 不重复记录
        assertEquals(listOf("q1", "q2"), progressStore.stored?.get("言语理解/成语辨析")?.answeredIDs)
    }

    // ---- deleteBank / refreshBank ----

    @Test
    fun `deleteBank clears bank session and progress and notifies`() = runTest(dispatcher) {
        val storage = InMemoryBankStorage().apply {
            populated = true
            meta = BankMeta(version = 1, round = 1, counts = mapOf("言语理解" to 3))
        }
        val sessionStore = FakePracticeSessionStore()
        val progressStore = FakePracticeProgressStore()
        val appState = AppState(FakeApi(), InMemorySettingsStore())
        val vm = makeVm(storage = storage, sessionStore = sessionStore, progressStore = progressStore, appState = appState)

        vm.ensureBankReady()
        advanceUntilIdle()
        vm.recordAnswered("言语理解", "成语辨析", "q1")
        advanceUntilIdle()

        vm.deleteBank()
        advanceUntilIdle()

        assertEquals(1, storage.clearCount)
        assertEquals(1, sessionStore.clearCount)
        assertEquals(1, progressStore.clearCount)
        assertEquals(BankPhase.Idle, vm.phase.value)
        assertEquals(0, vm.answeredCount("言语理解"))
        assertEquals("题库已删除，重新进入练习页会重新爬取全部试卷", appState.notice.value)
        assertEquals(1, appState.bankResetVersion.value)
    }

    @Test
    fun `refreshBank success clears session and progress and bumps round`() = runTest(dispatcher) {
        val api = FakeApi().apply { session = true }
        val storage = InMemoryBankStorage().apply {
            populated = true
            meta = BankMeta(version = 1, round = 2, counts = mapOf("言语理解" to 3))
        }
        val sessionStore = FakePracticeSessionStore()
        val progressStore = FakePracticeProgressStore()
        val vm = makeVm(api, storage, sessionStore, progressStore)

        vm.ensureBankReady()
        advanceUntilIdle()
        vm.recordAnswered("言语理解", "成语辨析", "q1")
        advanceUntilIdle()

        vm.refreshBank()
        advanceUntilIdle()

        assertEquals(BankPhase.Ready, vm.phase.value)
        assertEquals(3, storage.meta?.round)      // round 每次完成 +1
        assertEquals(1, sessionStore.clearCount)  // 成功后清 session
        assertEquals(1, progressStore.clearCount) // 成功后清进度
        assertEquals(0, vm.answeredCount("言语理解"))
    }

    @Test
    fun `refreshBank failure keeps old bank and progress`() = runTest(dispatcher) {
        val api = FakeApi().apply { session = true }
        val storage = InMemoryBankStorage().apply {
            populated = true
            meta = BankMeta(version = 1, round = 2, counts = mapOf("言语理解" to 3))
        }
        val sessionStore = FakePracticeSessionStore()
        val progressStore = FakePracticeProgressStore()
        val vm = makeVm(api, storage, sessionStore, progressStore)

        vm.ensureBankReady()
        advanceUntilIdle()

        api.examListError = ApiException(ApiException.UPSTREAM, "网络错误：boom")
        vm.refreshBank()
        advanceUntilIdle()

        assertTrue(vm.phase.value is BankPhase.Failed)
        assertEquals(2, storage.meta?.round)      // 旧题库保留
        assertEquals(0, sessionStore.clearCount)  // 失败不清
        assertEquals(0, progressStore.clearCount)
    }

    // ---- startPractice 恢复 ----

    private val ordered = listOf(
        question("q1"), question("q2"), question("q3"),
    )

    @Test
    fun `startPractice resumes matching saved run with its own order`() = runTest(dispatcher) {
        val storage = InMemoryBankStorage().apply { setCategory("言语理解", ordered) }
        val sessionStore = FakePracticeSessionStore().apply {
            stored = PracticeSession(
                category = "言语理解", subCategory = "成语辨析",
                questions = listOf(ordered[1], ordered[0], ordered[2]),   // 乱序存档
                index = 1,
                answers = listOf(
                    PracticeAnswer(selected = listOf("A"), revealed = true, correct = false),
                    PracticeAnswer(), PracticeAnswer(),
                ),
            )
        }
        val vm = makeVm(storage = storage, sessionStore = sessionStore)

        val result = vm.startPractice("言语理解", "成语辨析")

        assertTrue(result.resumed)
        assertEquals(listOf("q2", "q1", "q3"), result.session.questions.map { it.id })  // 不复洗
        assertEquals(1, result.session.index)
        assertEquals(1, result.session.wrongCount)
        assertEquals(0, sessionStore.saveCount)   // 恢复不重复持久化
    }

    @Test
    fun `startPractice different id set starts fresh session`() = runTest(dispatcher) {
        val storage = InMemoryBankStorage().apply { setCategory("言语理解", ordered) }
        val sessionStore = FakePracticeSessionStore().apply {
            stored = PracticeSession(
                category = "言语理解", subCategory = "成语辨析",
                questions = listOf(question("q9")), index = 0,
            )
        }
        val vm = makeVm(storage = storage, sessionStore = sessionStore)

        val result = vm.startPractice("言语理解", "成语辨析")

        assertFalse(result.resumed)
        assertEquals(listOf("q1", "q2", "q3"), result.session.questions.map { it.id })
        assertEquals(1, sessionStore.saveCount)   // 新会话持久化一次
    }

    // ---- 分类列表 ----

    @Test
    fun `openCategory groups subcategories with answered counts`() = runTest(dispatcher) {
        val storage = InMemoryBankStorage().apply {
            setCategory("言语理解", listOf(
                question("q1", subCategory = "成语辨析"),
                question("q2", subCategory = "虚词辨析", answer = null),
                question("q3", subCategory = "成语辨析"),
            ))
            populated = true
            meta = BankMeta(version = 1, round = 1, counts = mapOf("言语理解" to 3))
        }
        val progressStore = FakePracticeProgressStore().apply {
            stored = mapOf("言语理解/虚词辨析" to PracticeProgress(listOf("x1")))
        }
        val vm = makeVm(storage = storage, progressStore = progressStore)

        vm.ensureBankReady()
        advanceUntilIdle()
        vm.openCategory("言语理解")
        advanceUntilIdle()

        assertEquals(listOf("成语辨析", "虚词辨析"), vm.subcategories.value.map { it.name })
        assertEquals(2, vm.subcategories.value.first { it.name == "成语辨析" }.count)
        assertEquals(0, vm.subcategories.value.first { it.name == "成语辨析" }.answered)
        assertEquals(1, vm.subcategories.value.first { it.name == "虚词辨析" }.answered)
        assertEquals(1, vm.subcategories.value.first { it.name == "虚词辨析" }.count)
    }
}
