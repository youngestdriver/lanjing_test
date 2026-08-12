package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Domain.CookieCloudSync
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import com.qzh.lanjingquiz.Network.StoredCookie
import com.qzh.lanjingquiz.UI.HomeTab
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
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

    @Test fun `start routes home when session exists`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = makeState(api)
        state.start()
        advanceUntilIdle()   // start 先做云端拉取(未配置 → 立即返回),再决定路由
        assertEquals(Route.Home, state.route.value)
    }
    @Test fun `start routes login when no session`() = runTest {
        val state = makeState(FakeApi())
        state.start()
        advanceUntilIdle()
        assertEquals(Route.Login, state.route.value)
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
