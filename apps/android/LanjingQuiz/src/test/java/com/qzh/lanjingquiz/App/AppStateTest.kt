package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Domain.CloudConfig
import com.qzh.lanjingquiz.Domain.CookieCloudSync
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import com.qzh.lanjingquiz.Network.StoredCookie
import com.qzh.lanjingquiz.Network.TestConfig
import com.qzh.lanjingquiz.Support.CookieCloudCrypto
import com.qzh.lanjingquiz.UI.HomeTab
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppStateTest {
    // logout()/start()/finishLogin() 走内部 scope(Main.immediate),测试需注入 Main 派发器并推进调度器
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    /** 与生产等价的组件组合:会话假上游 + 内存设置/安全存储 + 未配置的 CookieCloud 同步。 */
    private fun makeState(api: FakeApi, settings: SettingsStore = InMemorySettingsStore()): AppState {
        val secure = InMemorySecureStore()
        val sync = CookieCloudSync(api, PrefsCookieStore(secure), secure, settings)
        return AppState(api, settings, sync)
    }

    /** 配置好 CookieCloud(settings + 密码,指向给定云端地址)的 AppState 组合。 */
    private fun makeCloudState(
        api: FakeApi,
        cloudUrl: String,
        settings: SettingsStore = InMemorySettingsStore(),
        secure: InMemorySecureStore = InMemorySecureStore(),
    ): AppState {
        settings.putString(
            "quiz.cookieCloud",
            Json.encodeToString(CloudConfig.serializer(), CloudConfig(true, cloudUrl, "uuid-1")),
        )
        secure.putString("cookiecloud.password", "pass-1")
        val sync = CookieCloudSync(api, PrefsCookieStore(secure), secure, settings)
        return AppState(api, settings, sync)
    }

    /**
     * 轮询等待路由变化。拉取走真实 MockWebServer IO,但 withTimeoutOrNull 的 4s 计时器
     * 走测试调度器的虚拟时钟 —— 用 runCurrent(不推进虚拟时钟)执行已就绪任务 + 真实
     * 睡眠等待 IO 完成,避免虚拟时钟提前触发 4s 超时。
     */
    private suspend fun TestScope.awaitRoute(state: AppState, expected: Route, timeoutMs: Long = 5000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (state.route.value != expected && System.currentTimeMillis() < deadline) {
            runCurrent()
            Thread.sleep(10)
        }
        runCurrent()
    }

    @Test fun `start routes home when session exists`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = makeState(api)
        state.start()
        advanceUntilIdle()   // start 先做云端拉取(未配置 → 立即返回),再决定路由
        assertEquals(Route.Home, state.route.value)
        assertTrue(state.booted.value)   // 路由决策完成 → splash 撤下
    }
    @Test fun `start routes login when no session`() = runTest {
        val state = makeState(FakeApi())
        state.start()
        advanceUntilIdle()
        assertEquals(Route.Login, state.route.value)
        assertTrue(state.booted.value)
    }
    @Test fun `handleSessionExpiry clears session and shows notice`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = makeState(api)
        state.handleSessionExpiry()
        assertEquals(Route.Login, state.route.value)
        assertEquals("登录已过期，请重新登录", state.notice.value)
        assertFalse(api.hasSession())
    }
    @Test fun `logout calls upstream then clears locally`() = runTest(dispatcher) {
        val api = FakeApi().apply { session = true }
        val state = makeState(api)
        state.logout()
        advanceUntilIdle()   // logout 现为异步(viewModelScope),等协程完成后再断言
        assertEquals(1, api.logoutCalls)
        assertFalse(api.hasSession())
        assertEquals(Route.Login, state.route.value)
    }
    @Test fun `finishLogin routes home and pushes cloud session after login`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = makeState(api)
        state.finishLogin()
        advanceUntilIdle()   // 路由后 fire-and-forget push(未配置 → no-op,不崩溃)
        assertEquals(Route.Home, state.route.value)
    }
    @Test fun `finishLogin stays on login when no session`() = runTest {
        val state = makeState(FakeApi())
        state.finishLogin()
        advanceUntilIdle()
        assertEquals(Route.Login, state.route.value)
    }
    @Test fun `syncNow delegates to CookieCloudSync`() = runTest {
        val state = makeState(FakeApi())
        val result = state.syncNow()
        assertEquals("CookieCloud 同步未配置", result.error)
        assertFalse(result.applied)
        assertFalse(result.pushed)
    }

    // —— 登录页云重试(retryCloudSyncIfNeeded;iOS LoginView .task 移植)——

    @Test fun `retryCloudSyncIfNeeded pulls cloud session and routes home`() = runTest(dispatcher) {
        val cloud = MockWebServer().apply { start() }
        val probe = MockWebServer().apply { start() }
        TestConfig.mockBaseUrl = probe.url("/").toString().trimEnd('/')
        try {
            // 远端 blob:含 lanjingweike sessionId 的密文 + 探活通过(有效会话)
            val plain = """{"cookie_data":{"test.lanjingweike.com":[{"name":"sessionId","value":"REMOTE","domain":"test.lanjingweike.com","path":"/","secure":true,"expirationDate":1755000000}]},"local_storage_data":{}}"""
            val (encrypted, type) = CookieCloudCrypto.encryptAny(plain, "uuid-1", "pass-1")
            cloud.enqueue(MockResponse().setBody("""{"encrypted":"$encrypted","crypto_type":"$type"}"""))
            probe.enqueue(MockResponse().setBody("""{"success":true}"""))

            val state = makeCloudState(FakeApi(), cloud.url("/").toString().trimEnd('/'))
            state.retryCloudSyncIfNeeded("", "")
            awaitRoute(state, Route.Home)

            assertEquals(Route.Home, state.route.value)
            assertTrue(cloud.requestCount >= 1)   // 确实执行了云端拉取
        } finally {
            cloud.shutdown()
            probe.shutdown()
            TestConfig.mockBaseUrl = null
        }
    }

    @Test fun `retryCloudSyncIfNeeded skips pull when user typed`() = runTest(dispatcher) {
        val cloud = MockWebServer().apply { start() }
        try {
            val state = makeCloudState(FakeApi(), cloud.url("/").toString().trimEnd('/'))
            state.retryCloudSyncIfNeeded("138", "123456")
            advanceUntilIdle()
            assertEquals(0, cloud.requestCount)   // 已输入 → 守卫拦截,不发任何请求
            assertEquals(Route.Login, state.route.value)
        } finally {
            cloud.shutdown()
        }
    }

    // —— 主题与会话状态(我的页复用) ——
    @Test fun `theme defaults to system`() = runTest {
        val state = makeState(FakeApi())
        assertEquals(ThemeMode.System, state.theme.value)
    }
    @Test fun `setTheme persists and toggleTheme flips light to dark`() = runTest {
        val store = InMemorySettingsStore()
        val state = makeState(FakeApi(), store)
        state.setTheme(ThemeMode.Light)
        assertEquals("light", store.getString("theme"))
        state.toggleTheme()
        assertEquals(ThemeMode.Dark, state.theme.value)
        assertEquals("dark", store.getString("theme"))
        state.toggleTheme()
        assertEquals(ThemeMode.Light, state.theme.value)
    }
    @Test fun `toggleTheme from system switches to fixed dark`() = runTest {
        val state = makeState(FakeApi())
        state.toggleTheme()
        assertEquals(ThemeMode.Dark, state.theme.value)
    }
    @Test fun `setFollowsSystem remembers manual choice and restores it`() = runTest {
        val store = InMemorySettingsStore()
        val state = makeState(FakeApi(), store)
        state.setTheme(ThemeMode.Dark)
        state.setFollowsSystem(true)
        assertEquals(ThemeMode.System, state.theme.value)
        assertEquals("dark", store.getString("theme.manual"))
        state.setFollowsSystem(false)
        assertEquals(ThemeMode.Dark, state.theme.value)
    }
    @Test fun `setAutoAdvance persists to settings key`() = runTest {
        val store = InMemorySettingsStore()
        val state = makeState(FakeApi(), store)
        assertFalse(state.autoAdvance.value)
        state.setAutoAdvance(true)
        assertTrue(state.autoAdvance.value)
        assertTrue(store.getBoolean("quiz.autoAdvanceOnCorrect", false))
    }
}
