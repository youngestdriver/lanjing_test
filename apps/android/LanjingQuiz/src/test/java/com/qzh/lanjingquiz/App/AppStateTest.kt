package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.UI.HomeTab
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class AppStateTest {
    @Test fun `start routes home when session exists`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = AppState(api, InMemorySettingsStore())
        state.start()
        assertEquals(Route.Home, state.route.value)
    }
    @Test fun `start routes login when no session`() = runTest {
        val state = AppState(FakeApi(), InMemorySettingsStore())
        state.start()
        assertEquals(Route.Login, state.route.value)
    }
    @Test fun `handleSessionExpiry clears session and shows notice`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = AppState(api, InMemorySettingsStore())
        state.handleSessionExpiry()
        assertEquals(Route.Login, state.route.value)
        assertEquals("登录已过期，请重新登录", state.notice.value)
        assertFalse(api.hasSession())
    }
    @Test fun `logout calls upstream then clears locally`() = runTest {
        val api = FakeApi().apply { session = true }
        val state = AppState(api, InMemorySettingsStore())
        state.logout()
        assertEquals(1, api.logoutCalls)
        assertFalse(api.hasSession())
        assertEquals(Route.Login, state.route.value)
    }

    // —— 主题与会话状态(供 T6 我的页复用) ——
    @Test fun `theme defaults to system`() = runTest {
        val state = AppState(FakeApi(), InMemorySettingsStore())
        assertEquals(ThemeMode.System, state.theme.value)
    }
    @Test fun `setTheme persists and toggleTheme flips light to dark`() = runTest {
        val store = InMemorySettingsStore()
        val state = AppState(FakeApi(), store)
        state.setTheme(ThemeMode.Light)
        assertEquals("light", store.getString("theme"))
        state.toggleTheme()
        assertEquals(ThemeMode.Dark, state.theme.value)
        assertEquals("dark", store.getString("theme"))
        state.toggleTheme()
        assertEquals(ThemeMode.Light, state.theme.value)
    }
    @Test fun `toggleTheme from system switches to fixed dark`() = runTest {
        val state = AppState(FakeApi(), InMemorySettingsStore())
        state.toggleTheme()
        assertEquals(ThemeMode.Dark, state.theme.value)
    }
    @Test fun `setFollowsSystem remembers manual choice and restores it`() = runTest {
        val store = InMemorySettingsStore()
        val state = AppState(FakeApi(), store)
        state.setTheme(ThemeMode.Dark)
        state.setFollowsSystem(true)
        assertEquals(ThemeMode.System, state.theme.value)
        assertEquals("dark", store.getString("theme.manual"))
        state.setFollowsSystem(false)
        assertEquals(ThemeMode.Dark, state.theme.value)
    }
    @Test fun `setAutoAdvance persists to settings key`() = runTest {
        val store = InMemorySettingsStore()
        val state = AppState(FakeApi(), store)
        assertFalse(state.autoAdvance.value)
        state.setAutoAdvance(true)
        assertTrue(state.autoAdvance.value)
        assertTrue(store.getBoolean("quiz.autoAdvanceOnCorrect", false))
    }
}
