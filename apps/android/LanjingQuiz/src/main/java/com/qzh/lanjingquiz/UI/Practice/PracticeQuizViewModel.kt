package com.qzh.lanjingquiz.UI.Practice

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.BankStorage
import com.qzh.lanjingquiz.Data.PracticeAnswer
import com.qzh.lanjingquiz.Data.PracticeProgress
import com.qzh.lanjingquiz.Data.PracticeProgressStore
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Data.PracticeSessionStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Domain.BankLogic
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random
import javax.inject.Inject

/**
 * 刷题引擎(iOS PracticeBankViewModel 作答/持久化部分 + PracticeQuizView 交互移植):
 * 单选即点即判 / 多选提交判(集合相等)/ 无答案 reveal 不计对错;reveal 后经本 VM 的
 * progressStore 记录进度(键 "$category/$subCategory",按 question.id 去重追加,
 * 等待持久化屏障同 iOS awaitSaveCount 模式)。
 *
 * **answers 以 question.id 为键**(决策):随机顺序开关切换重建会话顺序时,已答状态
 * 按题目 ID 保留,不因位置漂移。持久化时按当前顺序重建 session.answers(与 questions 对齐)。
 */
@HiltViewModel
class PracticeQuizViewModel @Inject constructor(
    private val appState: AppState,
    private val storage: BankStorage,
    private val sessionStore: PracticeSessionStore,
    private val progressStore: PracticeProgressStore,
    private val settings: SettingsStore,
) : ViewModel() {

    private val _session = MutableStateFlow<PracticeSession?>(null)
    val session: StateFlow<PracticeSession?> = _session.asStateFlow()

    private val _page = MutableStateFlow(0)
    val page: StateFlow<Int> = _page.asStateFlow()

    /** 当前题的多选待选集合(未提交)。 */
    private val _pendingMulti = MutableStateFlow<Set<String>>(emptySet())
    val pendingMulti: StateFlow<Set<String>> = _pendingMulti.asStateFlow()

    val showAnswerCard = MutableStateFlow(false)

    /** 随机顺序开关(键 practice.shuffle.<大类>);切换后按新开关重建会话顺序但保留已答。 */
    private val _shuffle = MutableStateFlow(false)
    val shuffle: StateFlow<Boolean> = _shuffle.asStateFlow()

    /** 本次进入是否恢复存档(一次性恢复横幅;consumeResumeNotice 清除,不持久化)。 */
    private val _resumedFromDisk = MutableStateFlow(false)
    val resumedFromDisk: StateFlow<Boolean> = _resumedFromDisk.asStateFlow()

    /** 练习答题卡无 section 概念(单 section 无 tabs) → 无选中 section。 */
    private val _selectedSection = MutableStateFlow<String?>(null)
    val selectedSection: StateFlow<String?> = _selectedSection.asStateFlow()

    // ---- 会话内部状态(answers 以 question.id 为键)----
    private var category = ""
    private var subCategory = ""
    private var questions: List<BankQuestion> = emptyList()
    private var index = 0
    private val answersById = mutableMapOf<String, PracticeAnswer>()
    private var progress: Map<String, PracticeProgress> = emptyMap()

    /** PracticeBankViewModel.startPractice 建/恢复会话后调用(幂等,可重复进入)。 */
    fun start(session: PracticeSession, resumed: Boolean = false) {
        this.category = session.category
        this.subCategory = session.subCategory
        this.questions = session.questions
        this.index = session.index
        answersById.clear()
        session.questions.forEachIndexed { i, q ->
            answersById[q.id] = session.answers.getOrNull(i) ?: PracticeAnswer()
        }
        _page.value = session.index
        _pendingMulti.value = currentAnswer()?.takeIf { !it.revealed }?.selected?.toSet() ?: emptySet()
        _resumedFromDisk.value = resumed
        _shuffle.value = settings.getBoolean(PracticeBankViewModel.SHUFFLE_KEY_PREFIX + category, false)
        _session.value = session
        progress = emptyMap()
        viewModelScope.launch { progress = progressStore.load() }
    }

    /** 恢复横幅"知道了"消除(不持久化,每次进入重置)。 */
    fun consumeResumeNotice() { _resumedFromDisk.value = false }

    // MARK: - 随机顺序

    /**
     * 切换随机顺序(键 practice.shuffle.<大类>):按新开关重建会话顺序
     * (固定种子供测试确定性问题),已答按题目 ID 保留;会话进行中切换同样生效。
     */
    fun setShuffle(enabled: Boolean, seed: ULong? = null) {
        settings.putBoolean(PracticeBankViewModel.SHUFFLE_KEY_PREFIX + category, enabled)
        _shuffle.value = enabled
        val natural = storage.readCategory(category).filter { it.subCategory == subCategory }
        val newOrder = if (enabled) {
            BankLogic.groupShuffleQuestions(natural, seed ?: Random.nextLong().toULong())
        } else {
            natural
        }
        val currentId = questions.getOrNull(index)?.id
        questions = newOrder
        index = currentId?.let { id ->
            newOrder.indexOfFirst { it.id == id }.takeIf { it >= 0 }
        } ?: index.coerceIn(0, newOrder.lastIndex.coerceAtLeast(0))
        _page.value = index
        _pendingMulti.value = currentAnswer()?.takeIf { !it.revealed }?.selected?.toSet() ?: emptySet()
        publishAndPersist()
    }

    // MARK: - 作答

    /** 单选/无答案即点即记;多选切待选集(未提交)。 */
    fun tapOption(letter: String) {
        val q = questions.getOrNull(index) ?: return
        if (answersById[q.id]?.revealed == true) return
        when {
            !isGradable(q) -> {
                // 无答案:selected=[字母]、revealed、correct=null(计 answeredCount 与进度,不计对错)
                answersById[q.id] = PracticeAnswer(selected = listOf(letter), revealed = true, correct = null)
                recordAnswered(q)
            }
            isMulti(q) -> {
                val selected = answersById[q.id]?.selected?.toMutableSet() ?: mutableSetOf()
                if (!selected.add(letter)) selected.remove(letter)
                answersById[q.id] = PracticeAnswer(selected = selected.toList(), revealed = false, correct = null)
                _pendingMulti.value = selected
            }
            else -> {
                val correct = q.answer?.letters?.contains(letter) == true
                answersById[q.id] = PracticeAnswer(selected = listOf(letter), revealed = true, correct = correct)
                recordAnswered(q)
            }
        }
        publishAndPersist()
    }

    /** 多选确认:完整集合相等才判对;reveal + 记进度。 */
    fun confirmSelection() {
        val q = questions.getOrNull(index) ?: return
        val answer = answersById[q.id] ?: return
        if (answer.revealed || answer.selected.isEmpty() || !isMulti(q)) return
        val correct = q.answer?.letters?.toSet() == answer.selected.toSet()
        answersById[q.id] = answer.copy(revealed = true, correct = correct)
        _pendingMulti.value = emptySet()
        recordAnswered(q)
        publishAndPersist()
    }

    /** 已揭晓答案的题目记入进度注册表(按 question.id 去重追加 + 保存)。 */
    private fun recordAnswered(question: BankQuestion) {
        val key = "${question.category}/${question.subCategory}"
        val entry = progress[key] ?: PracticeProgress()
        if (entry.answeredIDs.contains(question.id)) return
        progress = progress + (key to entry.copy(answeredIDs = entry.answeredIDs + question.id))
        val snapshot = progress
        viewModelScope.launch { runCatching { progressStore.save(snapshot) } }
    }

    // MARK: - 导航

    /** 下一页/完成(分页/答题卡跳转共用 goTo 单一路径)。 */
    fun nextQuestion() {
        if (index >= questions.size) return
        index += 1
        _page.value = index
        _pendingMulti.value = currentAnswer()?.takeIf { !it.revealed }?.selected?.toSet() ?: emptySet()
        if (index >= questions.size) {
            // 完成:清文件(已完成的会话永不恢复),内存保留供 summary
            viewModelScope.launch { runCatching { sessionStore.clear() } }
        } else {
            persist()
        }
        publish()
    }

    /** 答题卡 jump:任意题(已答/未答),per-question 状态从 answers 恢复;同索引/越界 no-op。 */
    fun goTo(index: Int) {
        if (index < 0 || index >= questions.size || index == this.index) return
        this.index = index
        _page.value = index
        _pendingMulti.value = currentAnswer()?.takeIf { !it.revealed }?.selected?.toSet() ?: emptySet()
        publishAndPersist()
    }

    /** 答题卡 section 过滤 —— 练习无 section 概念(单 section 无 tabs),保留接口。 */
    fun jumpToSection(section: String?) {
        _selectedSection.value = section
    }

    fun openAnswerCard() { showAnswerCard.value = true }
    fun closeAnswerCard() { showAnswerCard.value = false }

    /** 返回题型列表:清文件保留内存(仅 endSession/完成清文件,系统返回不清)。 */
    fun endSession() {
        viewModelScope.launch { runCatching { sessionStore.clear() } }
        _resumedFromDisk.value = false
    }

    // MARK: - 内部

    private fun currentAnswer(): PracticeAnswer? = questions.getOrNull(index)?.let { answersById[it.id] }

    private fun isMulti(q: BankQuestion): Boolean = q.answer is AnswerShape.Multi

    private fun isGradable(q: BankQuestion): Boolean =
        q.answer != null && q.answer !is AnswerShape.None

    /** answers(按 id)重建会话(与 questions 顺序对齐)并发布;统计/答题卡从此派生。 */
    private fun publish() {
        val s = _session.value ?: return
        _session.value = s.copy(
            index = index,
            answers = questions.map { answersById[it.id] ?: PracticeAnswer() },
        )
    }

    private fun publishAndPersist() {
        publish()
        persist()
    }

    /** 快照保存(fire-and-forget;失败静默,下次变更重写 —— iOS persist 语义)。 */
    private fun persist() {
        val snapshot = _session.value ?: return
        viewModelScope.launch { runCatching { sessionStore.save(snapshot) } }
    }
}
