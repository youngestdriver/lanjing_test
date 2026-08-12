package com.qzh.lanjingquiz.UI.Practice

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.Data.BankMeta
import com.qzh.lanjingquiz.Data.BankStorage
import com.qzh.lanjingquiz.Data.CrawlLogEntry
import com.qzh.lanjingquiz.Data.PracticeProgress
import com.qzh.lanjingquiz.Data.PracticeProgressStore
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Data.PracticeSessionStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Domain.BankLogic
import com.qzh.lanjingquiz.Domain.Crawler
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.UpstreamApi
import com.qzh.lanjingquiz.Support.Formatters
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random
import javax.inject.Inject

/** 练习页内部导航(Home tab 内;iOS PracticeRoute 等价物)。Hoist 在 AppState 使切 Tab 保留。 */
sealed interface PracticeRoute {
    data object Categories : PracticeRoute
    data class Subcategories(val category: String) : PracticeRoute
    data class Quiz(val category: String, val subCategory: String) : PracticeRoute
}

/** 题库可用性状态机(iOS PracticeBankViewModel.Phase 移植)。 */
sealed interface BankPhase {
    data object Idle : BankPhase
    data object Checking : BankPhase
    data object NeedsLogin : BankPhase
    data class Crawling(val progress: Crawler.CrawlProgress) : BankPhase
    data object Ready : BankPhase
    data class Failed(val message: String) : BankPhase
}

data class CategorySummary(val name: String, val count: Int, val answered: Int)
data class SubcategorySummary(val name: String, val count: Int, val answered: Int)

/** startPractice 结果:会话 + 是否从存档恢复(恢复横幅用)。 */
data class StartResult(val session: PracticeSession, val resumed: Boolean)

/**
 * 练习 Tab 引擎(iOS PracticeBankViewModel 移植):本地题库爬取门控
 * (首用直连蓝鲸平台爬取全部机考题库 → 大类 → 题型细分列表 + x/N 进度)、
 * 会话创建/恢复(恢复规则 = BankLogic.resumeCandidate)、进度注册表聚合与记录、
 * 题库管理(更新/删除,经 AppState.bankResetVersion 通知其它实例)。
 * 刷题本身在 PracticeQuizViewModel。
 */
@HiltViewModel
class PracticeBankViewModel @Inject constructor(
    private val api: UpstreamApi,
    private val storage: BankStorage,
    private val sessionStore: PracticeSessionStore,
    private val progressStore: PracticeProgressStore,
    private val settings: SettingsStore,
    private val appState: AppState,
    private val crawler: Crawler,
) : ViewModel() {

    private val _phase = MutableStateFlow<BankPhase>(BankPhase.Idle)
    val phase: StateFlow<BankPhase> = _phase.asStateFlow()

    private val _meta = MutableStateFlow<BankMeta?>(null)
    val meta: StateFlow<BankMeta?> = _meta.asStateFlow()

    private val _categories = MutableStateFlow<List<CategorySummary>>(emptyList())
    val categories: StateFlow<List<CategorySummary>> = _categories.asStateFlow()

    private val _subcategories = MutableStateFlow<List<SubcategorySummary>>(emptyList())
    val subcategories: StateFlow<List<SubcategorySummary>> = _subcategories.asStateFlow()

    /** 进度注册表内存副本(键 "category/subCategory")。 */
    private var progress: Map<String, PracticeProgress> = emptyMap()

    // MARK: - 题库可用性

    /** 练习入口:本地题库已就绪 → Ready;无会话 → NeedsLogin;否则全量爬取。Idle 才跑。 */
    fun ensureBankReady() {
        if (_phase.value != BankPhase.Idle) return
        _phase.value = BankPhase.Checking
        viewModelScope.launch {
            val meta = storage.readMeta()
            if (storage.isPopulated() && meta != null) {
                _meta.value = meta
                progress = progressStore.load()
                refreshCategories()
                _phase.value = BankPhase.Ready
                return@launch
            }
            if (!api.hasSession()) {
                _phase.value = BankPhase.NeedsLogin
                return@launch
            }
            crawl(force = false)
        }
    }

    /** 我的 > 更新题库:重爬全部,成功才原子替换;成功后清 session/progress(旧 ID 无意义)。 */
    fun refreshBank() {
        if (_phase.value is BankPhase.Crawling) return
        viewModelScope.launch {
            if (!api.hasSession()) {
                _phase.value = BankPhase.NeedsLogin
                return@launch
            }
            crawl(force = true)
            if (_phase.value is BankPhase.Ready) {
                runCatching { sessionStore.clear() }
                progress = emptyMap()
                runCatching { progressStore.clear() }
                refreshCategories()
            }
        }
    }

    /** 删除题库:清空本地库 + session/progress,通知 + bankResetVersion+1 触发重爬。 */
    fun deleteBank() {
        storage.clearAll()
        viewModelScope.launch { runCatching { sessionStore.clear() } }
        progress = emptyMap()
        viewModelScope.launch { runCatching { progressStore.clear() } }
        resetState()
        appState.bankResetVersion.value += 1
        appState.showNotice("题库已删除，重新进入练习页会重新爬取全部试卷")
    }

    /** 他处(我的)删除题库后的复位:下次 ensureBankReady 重爬。 */
    fun bankWasDeleted() {
        resetState()
        viewModelScope.launch { runCatching { sessionStore.clear() } }
        viewModelScope.launch { runCatching { progressStore.clear() } }
    }

    private fun resetState() {
        _phase.value = BankPhase.Idle
        _meta.value = null
        _categories.value = emptyList()
        _subcategories.value = emptyList()
        progress = emptyMap()
    }

    private suspend fun crawl(force: Boolean) {
        _phase.value = BankPhase.Crawling(Crawler.CrawlProgress(0, 0, null, CrawlLogEntry.STEP_PAPER_LIST))
        val result = crawler.crawl(refresh = force) { p ->
            if (_phase.value is BankPhase.Crawling) _phase.value = BankPhase.Crawling(p)
        }
        result.fold(
            onSuccess = {
                _meta.value = storage.readMeta()
                progress = progressStore.load()
                refreshCategories()
                _phase.value = BankPhase.Ready
            },
            onFailure = { e -> handleCrawlError(e) },
        )
    }

    /** 会话过期类错误 → AppState 统一处理回登录页;其余 → Failed 可重试。 */
    private fun handleCrawlError(e: Throwable) {
        if (e is ApiException && (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN)) {
            appState.handleSessionExpiry()
            _phase.value = BankPhase.NeedsLogin
        } else {
            _phase.value = BankPhase.Failed((e as? ApiException)?.message ?: e.message ?: "服务器响应异常")
        }
    }

    // MARK: - 分类列表

    private fun refreshCategories() {
        val meta = _meta.value ?: return
        _categories.value = BankLogic.categories.map { category ->
            CategorySummary(category, meta.counts[category] ?: 0, answeredCount(category))
        }
    }

    /** 加载某大类的题型细分列表(行内进度来自进度注册表,入口处强制刷新)。 */
    fun openCategory(category: String) {
        viewModelScope.launch {
            progress = progressStore.load()
            val expected = storage.readMeta()?.counts?.get(category) ?: 0
            val questions = storage.readCategory(category)
            if (questions.isEmpty() && expected > 0) {
                _phase.value = BankPhase.Failed("本地题库缺少 $category.jsonl，请在 我的 > 更新题库 重新爬取")
                return@launch
            }
            val groups = questions.groupBy { it.subCategory }
            _subcategories.value = groups.map { (name, group) ->
                SubcategorySummary(name, group.size, answeredCount(category, name))
            }
        }
    }

    // MARK: - 进度注册表

    /** 某题型细分的已答数(跨会话累计)。 */
    fun answeredCount(category: String, subCategory: String): Int =
        BankLogic.answeredCount(progress, category, subCategory)

    /** 某大类下所有题型细分的已答数之和(键前缀聚合)。 */
    fun answeredCount(category: String): Int = BankLogic.answeredCount(progress, category)

    /** 已揭晓答案的题目记入进度注册表(按 question.id 去重追加 + 保存)。 */
    fun recordAnswered(category: String, subCategory: String, questionId: String) {
        val key = "$category/$subCategory"
        val entry = progress[key] ?: PracticeProgress()
        if (entry.answeredIDs.contains(questionId)) return
        progress = progress + (key to entry.copy(answeredIDs = entry.answeredIDs + questionId))
        val snapshot = progress
        viewModelScope.launch { runCatching { progressStore.save(snapshot) } }
    }

    // MARK: - 会话

    /**
     * 本地会话开始(无网络):按题型细分筛选,可选洗牌(资料分析同材料保组);
     * BankLogic.resumeCandidate 命中则载入存档(不复洗、不重复持久化),否则新建并持久化。
     */
    suspend fun startPractice(category: String, subCategory: String): StartResult {
        val all = storage.readCategory(category)
        val questions = all.filter { it.subCategory == subCategory }
        val ordered = if (shuffleEnabled(category)) {
            BankLogic.groupShuffleQuestions(questions, Random.nextLong().toULong())
        } else {
            questions
        }
        val saved = sessionStore.load()
        BankLogic.resumeCandidate(saved, category, subCategory, ordered)?.let {
            return StartResult(it, true)
        }
        val session = PracticeSession(category, subCategory, ordered)
        runCatching { sessionStore.save(session) }
        return StartResult(session, false)
    }

    // MARK: - 随机顺序(每大类独立记忆,键 "practice.shuffle.<大类>")

    fun shuffleEnabled(category: String): Boolean =
        settings.getBoolean(SHUFFLE_KEY_PREFIX + category, false)

    fun setShuffleEnabled(enabled: Boolean, category: String) {
        settings.putBoolean(SHUFFLE_KEY_PREFIX + category, enabled)
    }

    // MARK: - 日志导出

    /** 生成爬取日志导出文本;空日志 → null(由 UI 提示"暂无爬取日志…")。 */
    fun exportLog(): String? {
        val entries = storage.readCrawlLog()
        if (entries.isEmpty()) return null
        return entries.joinToString("\n") { entry ->
            val paper = entry.paperName.ifBlank { "-" }
            val stepName = STEP_NAMES[entry.step] ?: entry.step
            val outcomeName = OUTCOME_NAMES[entry.outcome] ?: entry.outcome
            val message = entry.message?.let { "($it)" } ?: ""
            "[${Formatters.displayIso(entry.timestamp)}] $paper · $stepName — $outcomeName$message"
        }
    }

    companion object {
        const val SHUFFLE_KEY_PREFIX = "practice.shuffle."

        /** CrawlProgress.phase 机器名 → 显示名(spec §3.5 练习)。 */
        private val STEP_NAMES = mapOf(
            CrawlLogEntry.STEP_PAPER_LIST to "获取试卷列表",
            CrawlLogEntry.STEP_ENTER to "进入试卷",
            CrawlLogEntry.STEP_SAVE to "保存题目",
            CrawlLogEntry.STEP_END_ATTEMPT to "结束作答",
            CrawlLogEntry.STEP_SKIP to "跳过",
        )
        private val OUTCOME_NAMES = mapOf(
            CrawlLogEntry.OUTCOME_SUCCESS to "成功",
            CrawlLogEntry.OUTCOME_FAILURE to "失败",
            CrawlLogEntry.OUTCOME_SKIPPED to "跳过",
        )
    }
}
