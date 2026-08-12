package com.qzh.lanjingquiz.UI.Quiz

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.Domain.CardInfo
import com.qzh.lanjingquiz.Domain.ExamHtmlParser
import com.qzh.lanjingquiz.Domain.QuizLogic
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.Network.QuestionBatchRequest
import com.qzh.lanjingquiz.Network.QuestionDto
import com.qzh.lanjingquiz.Network.UpstreamApi
import com.qzh.lanjingquiz.Support.Formatters
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** 答题卡题目状态;state ∈ "unanswered"|"right"|"error"(spec §四)。 */
data class QuestionState(
    val questionsId: String,
    val uuId: String?,
    val num: String,
    val section: String,
    val combId: String?,
    val state: String,
    val marked: Boolean,
)

/**
 * 考试作答引擎 —— iOS QuizViewModel.swift 移植:
 * 进入(队列轮询)→ 批拉题 → 逐题作答(单选即点即判/多选提交判定)→ 标记(乐观+回滚)→
 * 每未答题 60s 倒计时(runID 防陈旧)→ 答对自动下一题(1200ms,手动导航取消)→ 交卷。
 */
@HiltViewModel
class QuizViewModel @Inject constructor(
    private val api: UpstreamApi,
    private val appState: AppState,
) : ViewModel() {

    enum class TimerMode { Active, Paused, Expired }

    private val _page = MutableStateFlow(0)
    val page: StateFlow<Int> = _page.asStateFlow()

    private val _questions = MutableStateFlow<List<QuestionDto>>(emptyList())
    val questions: StateFlow<List<QuestionDto>> = _questions.asStateFlow()

    private val _states = MutableStateFlow<List<QuestionState>>(emptyList())
    val states: StateFlow<List<QuestionState>> = _states.asStateFlow()

    /** testId → 已选字母(含从上游 test_ans 恢复的旧选)。 */
    private val _answers = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val answers: StateFlow<Map<String, List<String>>> = _answers.asStateFlow()

    private val _markedIds = MutableStateFlow<Set<String>>(emptySet())
    val markedIds: StateFlow<Set<String>> = _markedIds.asStateFlow()

    /** 答题卡 section tab:首段 null = "全部";单 section 时为空列表(UI 隐藏 tabs)。 */
    private val _sectionTabs = MutableStateFlow<List<String?>>(emptyList())
    val sectionTabs: StateFlow<List<String?>> = _sectionTabs.asStateFlow()

    private val _selectedSection = MutableStateFlow<String?>(null)
    val selectedSection: StateFlow<String?> = _selectedSection.asStateFlow()

    private val _timer = MutableStateFlow("01:00")
    val timer: StateFlow<String> = _timer.asStateFlow()

    private val _timerMode = MutableStateFlow(TimerMode.Paused)
    val timerMode: StateFlow<TimerMode> = _timerMode.asStateFlow()

    private val _isSubmitting = MutableStateFlow(false)
    val isSubmitting: StateFlow<Boolean> = _isSubmitting.asStateFlow()

    /** 当前题的多选待选集合(未提交)。 */
    private val _pendingMulti = MutableStateFlow<Set<String>>(emptySet())
    val pendingMulti: StateFlow<Set<String>> = _pendingMulti.asStateFlow()

    val showAnswerCard = MutableStateFlow(false)
    val showSubmitConfirm = MutableStateFlow(false)
    val showAbandonConfirm = MutableStateFlow(false)

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _loadPhase = MutableStateFlow<String?>(null)
    val loadPhase: StateFlow<String?> = _loadPhase.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // ---- 内部状态(iOS 移植)----
    private var exam: ExamDto? = null
    private var startedFor: String? = null
    private var examInfoId = ""
    private var examResultsId: String? = null
    /** 每问剩余秒数(未答时递减;答过恒 60)。 */
    private val remainingByQuestion = mutableMapOf<String, Int>()
    /** 标识唯一允许发布 UI 的计时任务(A→B→A 导航下 questionsId 不足以区分新旧任务)。 */
    private var timerRunID = 0
    private var timerJob: Job? = null
    /** 手动导航使待执行自动下一题失效。 */
    private var generation = 0
    private var autoAdvanceJob: Job? = null
    /** 每题多选待选集(testId → 字母)。 */
    private val pendingByQuestion = mutableMapOf<String, Set<String>>()
    private var autoAdvanceOnCorrect = false

    private fun isAnswered(testId: String): Boolean =
        _states.value.any { it.questionsId == testId && it.state != QuizLogic.STATE_UNANSWERED }

    private fun currentQuestion(): QuestionDto? =
        _questions.value.getOrNull(_page.value)

    private fun currentState(): QuestionState? =
        _states.value.getOrNull(_page.value)

    init {
        viewModelScope.launch {
            appState.autoAdvance.collect { autoAdvanceOnCorrect = it }
        }
    }

    // MARK: - 进入与加载

    /** QuizScreen LaunchedEffect 调用;同一 exam 幂等(离开答题页时 reset 解除)。 */
    fun start(exam: ExamDto) {
        val key = exam.id.toString()
        if (startedFor == key) return
        startedFor = key
        this.exam = exam
        load()
    }

    fun retry() {
        _errorMessage.value = null
        exam?.let { load() }
    }

    /** 离开答题页时清空,使下次进入重新走完整流程(iOS 每次进入新建 VM 的等价物)。 */
    fun reset() {
        stopTimer()
        autoAdvanceJob?.cancel()
        autoAdvanceJob = null
        startedFor = null
        _page.value = 0
        _questions.value = emptyList()
        _states.value = emptyList()
        _answers.value = emptyMap()
        _markedIds.value = emptySet()
        _sectionTabs.value = emptyList()
        _selectedSection.value = null
        _errorMessage.value = null
        examResultsId = null
        remainingByQuestion.clear()
        pendingByQuestion.clear()
        _pendingMulti.value = emptySet()
    }

    fun cancel() {
        stopTimer()
        autoAdvanceJob?.cancel()
        autoAdvanceJob = null
    }

    private fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _loadPhase.value = "进入考试…"
            try {
                val exam = exam ?: return@launch
                val session = api.enterExam(exam.id.toString(), isNew = exam.wfs == 1)
                examResultsId = session.examResultsId
                examInfoId = session.examInfoId
                _loadPhase.value = "加载题目…"
                val page = ExamHtmlParser.parse(
                    api.examStartHtml(exam.id.toString()),
                    fallbackExamInfoId = exam.id.toString(),
                    knownResultsId = session.examResultsId,
                )
                val questions = fetchAll(page.cards, session.examResultsId, session.examInfoId, session.uuid)
                applyLoaded(page, questions)
                _errorMessage.value = null
            } catch (e: ApiException) {
                if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
                    appState.handleSessionExpiry()
                } else {
                    _errorMessage.value = e.message
                }
            } finally {
                _isLoading.value = false
                _loadPhase.value = null
            }
        }
    }

    /** 批拉取:按 combId 分单元(单元内不混 combId),每批 ≤50(iOS fetchQuestionDTOs)。 */
    private suspend fun fetchAll(
        cards: List<CardInfo>,
        resultsId: String,
        infoId: String,
        uuid: String?,
    ): List<QuestionDto> {
        val combByTestId = cards.filter { it.combId != null }.associate { it.questionsId to it.combId!! }
        val units = mutableListOf<Pair<List<String>, String?>>()
        var unit = mutableListOf<String>()
        var unitComb: String? = null
        for (card in cards) {
            val comb = combByTestId[card.questionsId]
            if (unit.isNotEmpty() && (unitComb != comb || unit.size >= 50)) {
                units += unit.toList() to unitComb
                unit = mutableListOf()
                unitComb = null
            }
            unit += card.questionsId
            unitComb = comb
        }
        if (unit.isNotEmpty()) units += unit.toList() to unitComb

        val all = mutableListOf<QuestionDto>()
        for ((testIds, combId) in units) {
            all += api.fetchQuestions(QuestionBatchRequest(
                examResultsId = resultsId,
                examInfoId = infoId,
                testIds = testIds,
                uuids = testIds.map { uuid ?: "null" },
                combId = combId,
            ))
        }
        return all
    }

    private fun applyLoaded(page: com.qzh.lanjingquiz.Domain.ExamPage, fetched: List<QuestionDto>) {
        val byId = fetched.associateBy { it.id }
        // 题目顺序对齐卡片顺序(状态/分页按卡片索引)
        val questions = page.cards.mapIndexed { i, c -> byId[c.questionsId] ?: fetched.getOrNull(i) }
            .filterNotNull()
        _states.value = page.cards.map { c ->
            QuestionState(c.questionsId, c.uuId, c.number, c.section, c.combId, c.state, c.marked)
        }
        _questions.value = questions
        // 已选恢复自上游 test_ans("key1,key3," → {A,C})
        _answers.value = questions.mapNotNull { dto ->
            QuizLogic.keysToLetters(dto.testAns).takeIf { it.isNotEmpty() }?.let { dto.id to it }
        }.toMap()
        _markedIds.value = _states.value.filter { it.marked }.map { it.questionsId }.toSet()
        _sectionTabs.value = if (page.sections.size > 1) listOf(null) + page.sections else emptyList()
        val firstUnanswered = _states.value.indexOfFirst { it.state == QuizLogic.STATE_UNANSWERED }
        if (firstUnanswered >= 0) {
            _page.value = firstUnanswered
            indexChanged()
        }
        for (q in questions) {
            QuizLogic.keysToLetters(q.testAns).takeIf { it.isNotEmpty() }?.let {
                pendingByQuestion[q.id] = it.toSet()
            }
        }
        _pendingMulti.value = currentQuestion()?.let { pendingByQuestion[it.id] } ?: emptySet()
    }

    // MARK: - 导航

    /** 分页单一路径(手势/答题卡/自动下一题都经此):计时重启一次 + runID 防陈旧。 */
    fun goTo(index: Int) {
        if (index < 0 || index >= _states.value.size || index == _page.value) return
        _page.value = index
        indexChanged()
        _pendingMulti.value = pendingByQuestion[currentQuestion()?.id] ?: emptySet()
    }

    fun nextQuestion() {
        val target = QuizLogic.nextIndex(after = _page.value, states = _states.value.map { it.state })
        goTo(target)
    }

    private fun indexChanged() {
        generation += 1
        restartTimerForCurrent()
    }

    // MARK: - 作答

    /** 单选:立即提交+判定(web parity);多选:切换待选集。 */
    fun tapOption(letter: String) {
        val question = currentQuestion() ?: return
        if (isAnswered(question.id)) return
        if (QuizLogic.isMulti(question)) {
            val pending = pendingByQuestion[question.id]?.toMutableSet() ?: mutableSetOf()
            if (!pending.add(letter)) pending.remove(letter)
            pendingByQuestion[question.id] = pending
            _pendingMulti.value = pending
        } else {
            submitAnswer(
                letters = listOf(letter),
                correct = QuizLogic.correctLetters(question).contains(letter),
                question = question,
            )
        }
    }

    /** 多选确认:完整集合相等才判对。 */
    fun confirmSelection() {
        val question = currentQuestion() ?: return
        if (!QuizLogic.isMulti(question) || isAnswered(question.id)) return
        val selected = pendingByQuestion[question.id] ?: emptySet()
        if (selected.isEmpty()) return
        val ordered = listOf("A", "B", "C", "D").filter { selected.contains(it) }
        val correct = selected.isNotEmpty() && selected == QuizLogic.correctLetters(question).toSet()
        submitAnswer(letters = ordered, correct = correct, question = question)
    }

    /** 核心判定:更新状态/停表/上游上报(fire-and-forget)/答对自动下一题。 */
    private fun submitAnswer(letters: List<String>, correct: Boolean, question: QuestionDto) {
        val idx = _states.value.indexOfFirst { it.questionsId == question.id }
        if (idx >= 0) {
            val newStates = _states.value.toMutableList()
            newStates[idx] = newStates[idx].copy(state = if (correct) QuizLogic.STATE_RIGHT else QuizLogic.STATE_ERROR)
            _states.value = newStates
        }
        _answers.value = _answers.value + (question.id to letters.distinct().sorted())
        pendingByQuestion.remove(question.id)
        _pendingMulti.value = emptySet()
        stopTimerAndPause()

        val testAns = QuizLogic.lettersToKeys(letters)
        val resultsId = examResultsId
        if (resultsId != null) {
            viewModelScope.launch {
                try {
                    api.submitAnswer(resultsId, examInfoId, question.id, testAns, correct)
                } catch (e: ApiException) {
                    handleNonSessionError(e)
                }
            }
        }
        if (correct && autoAdvanceOnCorrect) scheduleAutoAdvance()
    }

    // MARK: - 标记

    /** 🔖 乐观标记 + fire-and-forget 上报;失败(过期类除外)回滚。 */
    fun toggleMark() {
        val question = currentQuestion() ?: return
        val resultsId = examResultsId ?: return
        val newValue = !_markedIds.value.contains(question.id)
        applyMark(question.id, newValue)
        viewModelScope.launch {
            try {
                api.markQuestion(question.id, resultsId, examInfoId, newValue)
            } catch (e: ApiException) {
                if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
                    appState.handleSessionExpiry()
                } else {
                    applyMark(question.id, !newValue)   // 回滚
                }
            }
        }
    }

    private fun applyMark(testId: String, value: Boolean) {
        val newMarked = _markedIds.value.toMutableSet()
        if (value) newMarked.add(testId) else newMarked.remove(testId)
        _markedIds.value = newMarked
        val idx = _states.value.indexOfFirst { it.questionsId == testId }
        if (idx >= 0) {
            val newStates = _states.value.toMutableList()
            newStates[idx] = newStates[idx].copy(marked = value)
            _states.value = newStates
        }
    }

    // MARK: - 分区跳转

    fun jumpToSection(section: String?) {
        _selectedSection.value = section
        val target = section?.let { s ->
            _states.value.indexOfFirst { it.section == s && it.state == QuizLogic.STATE_UNANSWERED }
                .takeIf { it >= 0 }
                ?: _states.value.indexOfFirst { it.section == s }.takeIf { it >= 0 }
        }
        if (target != null) goTo(target)
    }

    // MARK: - 交卷 / 放弃(两段确认由 UI 层做)

    fun submit() { showSubmitConfirm.value = true }
    fun abandon() { showAbandonConfirm.value = true }

    fun submitConfirmed() {
        if (_isSubmitting.value) return
        val resultsId = examResultsId ?: run {
            appState.showNotice("无法获取考试记录 ID")
            return
        }
        // 同步置位防重入(二次调用不重复网络请求)
        _isSubmitting.value = true
        viewModelScope.launch {
            try {
                val result = api.submitExam(examInfoId, resultsId)
                val name = exam?.name.orEmpty()
                appState.navigateTo(Route.Result(result, name))
            } catch (e: ApiException) {
                handleNonSessionError(e)
            } finally {
                _isSubmitting.value = false
            }
        }
    }

    /** 放弃:best-effort 交卷后回考试列表(失败也回)。 */
    fun abandonConfirmed() {
        val resultsId = examResultsId
        viewModelScope.launch {
            if (resultsId != null) {
                try { api.submitExam(examInfoId, resultsId) } catch (e: ApiException) {
                    if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
                        appState.handleSessionExpiry()
                    }
                }
            }
            appState.selectedTab.value = com.qzh.lanjingquiz.UI.HomeTab.Exams
            appState.navigateTo(Route.Home)
        }
    }

    fun openAnswerCard() { showAnswerCard.value = true }
    fun closeAnswerCard() { showAnswerCard.value = false }

    // MARK: - 计时器

    private fun stopTimer() {
        timerRunID += 1
        timerJob?.cancel()
        timerJob = null
    }

    private fun stopTimerAndPause() {
        stopTimer()
        _timerMode.value = TimerMode.Paused
        _timer.value = "01:00"
    }

    /** 每未答题 60s 倒计时(mmss);答过题停表 "01:00";过期 "00:00"。 */
    private fun restartTimerForCurrent() {
        stopTimer()
        val question = currentQuestion() ?: run {
            _timerMode.value = TimerMode.Paused
            return
        }
        if (isAnswered(question.id)) {
            // Web parity:答过的题显示停表的 01:00
            _timerMode.value = TimerMode.Paused
            _timer.value = "01:00"
            return
        }
        val remaining = remainingByQuestion[question.id] ?: 60
        if (remaining <= 0) {
            _timerMode.value = TimerMode.Expired
            _timer.value = "00:00"
            return
        }
        _timerMode.value = TimerMode.Active
        _timer.value = Formatters.mmss(remaining)
        val qId = question.id
        val runID = timerRunID
        val pageAtStart = _page.value
        timerJob = viewModelScope.launch {
            var seconds = remaining
            while (seconds > 0) {
                delay(1000)
                if (timerRunID != runID) return@launch      // 已被更新任务取代
                if (_page.value != pageAtStart) return@launch  // 当前题已变化
                if (isAnswered(qId)) return@launch          // 作答后停表
                seconds -= 1
                remainingByQuestion[qId] = seconds
                _timer.value = Formatters.mmss(seconds)
                if (seconds == 0) {
                    _timerMode.value = TimerMode.Expired
                    return@launch
                }
            }
        }
    }

    // MARK: - 自动下一题

    /** 答对且开启 autoAdvance → 1200ms 后 nextQuestion;任何手动导航(generation++)取消。 */
    private fun scheduleAutoAdvance() {
        autoAdvanceJob?.cancel()
        val token = generation
        autoAdvanceJob = viewModelScope.launch {
            delay(1200)
            if (token != generation) return@launch
            nextQuestion()
        }
    }

    // MARK: - 错误处理

    /** 非会话级错误:通知横幅展示(iOS 对提交/标记错误无可见反馈,安卓侧改为可见通知)。 */
    private fun handleNonSessionError(e: ApiException) {
        if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
            appState.handleSessionExpiry()
        } else {
            appState.showNotice(e.message)
        }
    }
}
