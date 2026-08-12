package com.qzh.lanjingquiz.Network

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * CookieCloud 客户端端点契约(iOS CookieCloudClient 移植):
 * POST {server}/update(成功 iff HTTP<300 且 {"action":"done"})、GET {server}/get/{uuid}(404 → null)、
 * 上游探活 POST {baseURL}/exam/current_exam_list(独立 client 显式发 Cookie 头,过期三规则判定)。
 */
class CookieCloudClientTest {
    private lateinit var server: MockWebServer        // CookieCloud 服务器
    private lateinit var probeServer: MockWebServer   // 上游探活服务器
    private lateinit var client: CookieCloudClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        probeServer = MockWebServer()
        probeServer.start()
        client = CookieCloudClient(server.url("/").toString().trimEnd('/')) {
            probeServer.url("/").toString().trimEnd('/')
        }
    }

    @After
    fun tearDown() {
        server.shutdown()
        probeServer.shutdown()
    }

    @Test
    fun `update posts uuid encrypted crypto_type and accepts action done`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"action":"done"}"""))
        client.update("u1", "abc", "aes-128-cbc-fixed")
        val req = server.takeRequest()
        assertEquals("/update", req.path)
        assertEquals("POST", req.method)
        assertEquals("application/json; charset=utf-8", req.getHeader("Content-Type"))
        val body = req.body.readUtf8()
        assertTrue(body.contains("\"uuid\":\"u1\""))
        assertTrue(body.contains("\"encrypted\":\"abc\""))
        assertTrue(body.contains("\"crypto_type\":\"aes-128-cbc-fixed\""))
    }

    @Test
    fun `update defaults crypto type to aes-128-cbc-fixed`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"action":"done"}"""))
        client.update("u1", "abc")
        assertTrue(server.takeRequest().body.readUtf8().contains("\"crypto_type\":\"aes-128-cbc-fixed\""))
    }

    @Test
    fun `update rejects non-done action`() {
        server.enqueue(MockResponse().setBody("""{"action":"wait"}"""))
        assertThrows(Exception::class.java) { runBlocking { client.update("u1", "abc") } }
    }

    @Test
    fun `update rejects http error status`() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertThrows(Exception::class.java) { runBlocking { client.update("u1", "abc") } }
    }

    @Test
    fun `get returns null on 404`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        assertNull(client.get("u1"))
        assertEquals("/get/u1", server.takeRequest().path)
    }

    @Test
    fun `get returns encrypted and cryptoType`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"encrypted":"xyz","crypto_type":"legacy"}"""))
        assertEquals("xyz" to "legacy", client.get("u1"))
    }

    @Test
    fun `get returns null cryptoType when missing`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"encrypted":"xyz"}"""))
        assertEquals("xyz" to null, client.get("u1"))
    }

    @Test
    fun `get throws on other statuses`() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertThrows(Exception::class.java) { runBlocking { client.get("u1") } }
    }

    @Test
    fun `probeSession returns false without sessionId in jar`() = runBlocking {
        assertFalse(client.probeSession("foo=bar"))
        assertEquals(0, server.requestCount)   // 无 sessionId → 不发探活请求
        assertEquals(0, probeServer.requestCount)
    }

    @Test
    fun `probeSession posts to exam list with the jar as cookie header`() = runBlocking {
        probeServer.enqueue(MockResponse().setBody("""{"success":true}"""))
        assertTrue(client.probeSession("sessionId=S1; foo=bar"))
        val req = probeServer.takeRequest()
        assertEquals("/exam/current_exam_list", req.path)
        assertEquals("POST", req.method)
        assertEquals("page=1&pageSize=1", req.body.readUtf8())
        assertEquals("sessionId=S1; foo=bar", req.getHeader("Cookie"))
    }

    @Test
    fun `probeSession rejects login page html`() = runBlocking {
        probeServer.enqueue(MockResponse().setBody(
            "<!DOCTYPE html><html><head><title>登录</title></head><body><form action=\"/login/account/login\">...</form></body></html>",
        ))
        assertFalse(client.probeSession("sessionId=S1"))
    }

    @Test
    fun `probeSession rejects onlineStatus 0`() = runBlocking {
        probeServer.enqueue(MockResponse().setBody("""{"onlineStatus":0}"""))
        assertFalse(client.probeSession("sessionId=S1"))
    }

    @Test
    fun `probeSession returns false on network error`() = runBlocking {
        val dead = CookieCloudClient("http://127.0.0.1:1") { "http://127.0.0.1:1" }
        assertFalse(dead.probeSession("sessionId=S1"))
    }
}
