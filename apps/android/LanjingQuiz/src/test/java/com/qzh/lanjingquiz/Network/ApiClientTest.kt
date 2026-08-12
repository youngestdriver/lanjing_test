package com.qzh.lanjingquiz.Network

import com.qzh.lanjingquiz.Data.InMemorySecureStore
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ApiClientTest {
    private lateinit var server: MockWebServer
    private lateinit var store: InMemorySecureStore
    private lateinit var cookieStore: PrefsCookieStore
    private lateinit var jar: PersistentCookieJar
    private lateinit var client: ApiClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        store = InMemorySecureStore()
        cookieStore = PrefsCookieStore(store)
        jar = PersistentCookieJar(cookieStore)
        val http = OkHttpClient.Builder()
            .cookieJar(jar)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
        client = ApiClient(http, jar, server.url("/").toString().trimEnd('/'))
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun seedSession() {
        cookieStore.save(listOf(
            StoredCookie("sessionId", "S1", "127.0.0.1", "/", false, false, null, true, null)))
    }

    @Test
    fun `login success stores session cookie`() = runBlocking {
        server.enqueue(MockResponse()
            .setHeader("Set-Cookie", "sessionId=abc; Path=/")
            .setBody("""{"success":true}"""))
        client.login("13800000000", "123456")
        assertTrue(client.hasSession())
        assertEquals("sessionId=abc", jar.headerStringForBase())
    }

    @Test
    fun `login failure throws upstream error with desc`() {
        server.enqueue(MockResponse().setBody("""{"success":false,"desc":"密码错误"}"""))
        val e = assertThrows(ApiException::class.java) {
            runBlocking { client.login("13800000000", "123456") }
        }
        assertEquals(ApiException.UPSTREAM, e.code)
        assertEquals("密码错误", e.message)
    }

    @Test
    fun `login page html body triggers session expiry and clears cookies`() {
        seedSession()
        server.enqueue(MockResponse().setBody(
            """<!DOCTYPE html><html><body><form action="/login/account/login"></form></body></html>"""))
        val e = assertThrows(ApiException::class.java) {
            runBlocking { client.examList() }
        }
        assertEquals(ApiException.SESSION_EXPIRED, e.code)
        assertEquals("登录已过期，请重新登录", e.message)
        assertFalse(client.hasSession())
    }

    @Test
    fun `onlineStatus zero triggers session expiry`() {
        seedSession()
        server.enqueue(MockResponse().setBody("""{"onlineStatus":"0"}"""))
        val e = assertThrows(ApiException::class.java) {
            runBlocking { client.examList() }
        }
        assertEquals(ApiException.SESSION_EXPIRED, e.code)
        assertFalse(client.hasSession())
    }

    @Test
    fun `redirect to login page triggers session expiry`() {
        seedSession()
        server.enqueue(MockResponse()
            .setResponseCode(302)
            .setHeader("Location", "/login/account/login"))
        val e = assertThrows(ApiException::class.java) {
            runBlocking { client.login("13800000000", "123456") }
        }
        assertEquals(ApiException.SESSION_EXPIRED, e.code)
        assertFalse(client.hasSession())
    }

    @Test
    fun `warmUpJsSession never detects expiry`() = runBlocking {
        server.enqueue(MockResponse().setBody(
            """<!DOCTYPE html><html><body><form action="/login/account/login"></form></body></html>"""))
        client.warmUpJsSession() // 过期页也不抛,仅暖机
        assertTrue(server.requestCount == 1)
    }

    @Test
    fun `upstream non-2xx throws upstream error`() {
        server.enqueue(MockResponse().setResponseCode(500).setBody("oops"))
        val e = assertThrows(ApiException::class.java) {
            runBlocking { client.examList() }
        }
        assertEquals(ApiException.UPSTREAM, e.code)
        assertEquals("服务器响应异常", e.message)
    }

    @Test
    fun `detectSessionExpiry rule 2 and 3`() {
        assertTrue(client.detectSessionExpiry(200,
            """<!DOCTYPE html><html><form action="/login/account/login"></form></html>"""))
        assertTrue(client.detectSessionExpiry(200, """{"onlineStatus":0}"""))
        assertTrue(client.detectSessionExpiry(200, """{"onlineStatus":"0"}"""))
        assertFalse(client.detectSessionExpiry(200, """{"onlineStatus":1}"""))
        assertFalse(client.detectSessionExpiry(200, """{"onlineStatus":10}"""))
        assertFalse(client.detectSessionExpiry(200, """{"success":true}"""))
    }

    @Test
    fun `enterExam follows redirect and parses js vars`() = runBlocking {
        server.enqueue(MockResponse()
            .setResponseCode(302)
            .setHeader("Location", "/exam/landing")
            .setBody(""))
        server.enqueue(MockResponse().setBody(""))                              // 跟随后的落点
        server.enqueue(MockResponse().setBody("{}"))                            // faceCheckCondition
        server.enqueue(MockResponse().setBody("""{"bizContent":{"isOk":true}}""")) // start_exam_queue
        server.enqueue(MockResponse().setBody("true"))                          // test_complete
        server.enqueue(MockResponse().setBody(
            "<html><head><script>var exam_results_id = '87380582'; var exam_info_id = '1439658'; var uuId = 'u1';</script></head></html>"))
        val result = client.enterExam("1439658")
        assertEquals("87380582", result.examResultsId)
        assertEquals("1439658", result.examInfoId)
        assertEquals("u1", result.uuid)
    }
}
