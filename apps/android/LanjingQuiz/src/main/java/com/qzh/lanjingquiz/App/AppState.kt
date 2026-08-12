package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.Network.ExamResult
import com.qzh.lanjingquiz.Network.UpstreamApi
import com.qzh.lanjingquiz.UI.HomeTab
import com.qzh.lanjingquiz.UI.Practice.PracticeRoute
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/** 应用路由;Quiz/Result 携带 Task 1 DTO(T3 消费)。 */
sealed interface Route {
    data object Login : Route
    data object Home : Route
    data class Quiz(val exam: ExamDto) : Route
    data class Result(val result: ExamResult, val examName: String) : Route
}

/** 外观模式;rawValue 与 iOS UserDefaults "theme" 键的值逐字一致。 */
enum class ThemeMode(val rawValue: String) {
    Light("light"), Dark("dark"), System("system");

    companion object {
        fun fromRaw(raw: String?): ThemeMode = entries.firstOrNull { it.rawValue == raw } ?: System
    }
}

/**
 * 应用级状态单例(路由/通知/主题/自动下一题开关)。
 * 注:早期为 @HiltViewModel;T3 起改为普通 @Singleton —— Hilt 禁止把 @HiltViewModel 注入
 * 到其他 ViewModel 构造器(QuizViewModel/ExamListViewModel 均消费 AppState)。
 */
@Singleton
class AppState @Inject constructor(
    private val api: UpstreamApi,
    private val settings: SettingsStore,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _route = MutableStateFlow<Route>(Route.Login)
    val route: StateFlow<Route> = _route.asStateFlow()

    /** HomeTabHost 直接写值(brief AppRoot 接线),故暴露 MutableStateFlow。 */
    val selectedTab = MutableStateFlow(HomeTab.Exams)

    /** 练习页内部导航(Home tab 内;iOS NavigationStack 等价物):分类 → 题型 → 刷题。
     *  Hoist 到 AppState 使切 Tab 后练习导航保留。 */
    val practiceRoute = MutableStateFlow<PracticeRoute>(PracticeRoute.Categories)

    /** 删除题库版本号:我的 > 删除题库 +1,练习页 VM 据此重置并重爬(iOS bankResetVersion)。 */
    val bankResetVersion = MutableStateFlow(0)

    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()

    private val _theme = MutableStateFlow(loadTheme())
    val theme: StateFlow<ThemeMode> = _theme.asStateFlow()

    private val _autoAdvance = MutableStateFlow(settings.getBoolean(KEY_AUTO_ADVANCE, false))
    val autoAdvance: StateFlow<Boolean> = _autoAdvance.asStateFlow()

    /** 启动:有会话 → 首页,否则登录页。 */
    fun start() {
        // T6: CookieCloud pull
        navigateTo(if (api.hasSession()) Route.Home else Route.Login)
    }

    /** 登录成功(或该页会话恢复)后:有会话 → 首页,否则仍登录页。 */
    fun finishLogin() {
        navigateTo(if (api.hasSession()) Route.Home else Route.Login)
    }

    /** 会话失效:清会话 + 通知 + 回登录页。 */
    fun handleSessionExpiry() {
        api.clearSession()
        showNotice("登录已过期，请重新登录")
        navigateTo(Route.Login)
    }

    /** 退出登录:异步 best-effort 上游注销(异常吞掉),随后清本地会话、回登录页并复位 Tab。
     *  不在调用线程阻塞(ApiClient.logout 内部已吞错误,runCatching 为双保险)。 */
    fun logout() {
        scope.launch {
            runCatching { api.logout() }
            api.clearSession()
            navigateTo(Route.Login)
            selectedTab.value = HomeTab.Exams
        }
    }

    /** 唯一写 route 的入口;路由切换一律走它。 */
    fun navigateTo(route: Route) { _route.value = route }

    fun showNotice(text: String?) { _notice.value = text }

    fun setTheme(mode: ThemeMode) {
        _theme.value = mode
        settings.putString(KEY_THEME, mode.rawValue)
    }

    /** 跟随系统开关:开启时记住当前手动选择,关闭时恢复(iOS setFollowsSystem 语义)。 */
    fun setFollowsSystem(follows: Boolean) {
        if (follows) {
            if (_theme.value != ThemeMode.System) {
                settings.putString(KEY_THEME_MANUAL, _theme.value.rawValue)
            }
            setTheme(ThemeMode.System)
        } else {
            setTheme(loadManualTheme())
        }
    }

    /** 考试页快速切换:Light↔Dark;System → 固定 Dark(退出跟随系统)。 */
    fun toggleTheme() {
        setTheme(if (_theme.value == ThemeMode.Dark) ThemeMode.Light else ThemeMode.Dark)
    }

    fun setAutoAdvance(b: Boolean) {
        _autoAdvance.value = b
        settings.putBoolean(KEY_AUTO_ADVANCE, b)
    }

    private fun loadTheme(): ThemeMode = ThemeMode.fromRaw(settings.getString(KEY_THEME))

    /** iOS Theme.loadManual() 缺省 light。 */
    private fun loadManualTheme(): ThemeMode =
        entriesOrNull(settings.getString(KEY_THEME_MANUAL)) ?: ThemeMode.Light

    private fun entriesOrNull(raw: String?): ThemeMode? =
        ThemeMode.entries.firstOrNull { it.rawValue == raw }

    companion object {
        private const val KEY_THEME = "theme"
        private const val KEY_THEME_MANUAL = "theme.manual"
        private const val KEY_AUTO_ADVANCE = "quiz.autoAdvanceOnCorrect"
    }
}
