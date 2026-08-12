package com.qzh.lanjingquiz.UI.Login

import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.Domain.CookieCloudSync
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.PrefsCookieStore
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LoginViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    @Test fun `empty phone and password shows validation error without calling login`() = runTest(dispatcher) {
        val api = FakeApi()
        val vm = LoginViewModel(api)
        vm.submit()
        assertEquals("请输入手机号和密码", vm.errorMessage.value)
        assertEquals(0, api.loginCalls)
    }

    @Test fun `whitespace-only phone shows validation error`() = runTest(dispatcher) {
        val api = FakeApi()
        val vm = LoginViewModel(api)
        vm.phone.value = "   "
        vm.password.value = "123456"
        vm.submit()
        assertEquals("请输入手机号和密码", vm.errorMessage.value)
        assertEquals(0, api.loginCalls)
    }

    @Test fun `whitespace-padded phone is normalized before calling login`() = runTest(dispatcher) {
        val api = FakeApi()
        val vm = LoginViewModel(api)
        vm.phone.value = " 138 0000 0000 "
        vm.password.value = "123456"
        vm.submit()
        advanceUntilIdle()
        assertEquals(1, api.loginCalls)
        assertEquals("13800000000", api.lastLoginPhone)
    }

    @Test fun `upstream login failure surfaces error message`() = runTest(dispatcher) {
        val api = FakeApi().apply { loginError = ApiException(ApiException.UPSTREAM, "密码错误") }
        val vm = LoginViewModel(api)
        vm.phone.value = "13800000000"
        vm.password.value = "123456"
        vm.submit()
        advanceUntilIdle()
        assertEquals("密码错误", vm.errorMessage.value)
        assertFalse(vm.isSubmitting.value)
    }

    @Test fun `session expired during login does not surface message and invokes session error`() = runTest(dispatcher) {
        val api = FakeApi().apply { loginError = ApiException.SESSION_EXPIRED_ERROR }
        val vm = LoginViewModel(api)
        var sessionError = false
        vm.onSessionError = { sessionError = true }
        vm.phone.value = "13800000000"
        vm.password.value = "123456"
        vm.submit()
        advanceUntilIdle()
        assertNull(vm.errorMessage.value)
        assertTrue(sessionError)
    }

    @Test fun `successful login invokes onFinished callback`() = runTest(dispatcher) {
        val api = FakeApi()
        val vm = LoginViewModel(api)
        var finished = false
        vm.onFinished = { finished = true }
        vm.phone.value = "13800000000"
        vm.password.value = "123456"
        vm.submit()
        advanceUntilIdle()
        assertTrue(finished)
        assertNull(vm.errorMessage.value)
        assertFalse(vm.isSubmitting.value)
    }

    @Test fun `successful login routes home through wired appState finishLogin`() = runTest(dispatcher) {
        val api = FakeApi()
        val settings = InMemorySettingsStore()
        val appState = AppState(api, settings, CookieCloudSync(api, PrefsCookieStore(InMemorySecureStore()), InMemorySecureStore(), settings))
        val vm = LoginViewModel(api)
        vm.onFinished = appState::finishLogin
        vm.phone.value = "13800000000"
        vm.password.value = "123456"
        vm.submit()
        advanceUntilIdle()
        assertEquals(Route.Home, appState.route.value)
    }
}
