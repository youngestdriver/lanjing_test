package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Data.InMemorySettingsStore
import com.qzh.lanjingquiz.FakeApi
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import com.qzh.lanjingquiz.Network.StoredCookie
import com.qzh.lanjingquiz.Network.TestConfig
import com.qzh.lanjingquiz.Support.CookieCloudCrypto
import com.qzh.lanjingquiz.Support.Hashers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * CookieCloud 同步协调器(iOS CookieCloudSync 移植):登录后推送去重(hash 未变 no-op)、
 * 启动拉取(4s 边界;远端有效 + probe 通过才 apply)、手动双向探活(syncNow)、
 * cookie_data 构造/解析/合并逐字 spec §3.4。
 */
class CookieCloudSyncTest {
    private lateinit var server: MockWebServer       // CookieCloud 服务器
    private lateinit var probeServer: MockWebServer  // 上游(探活用)
    private val api = FakeApi()
    private lateinit var secure: InMemorySecureStore
    private lateinit var settings: InMemorySettingsStore
    private lateinit var cookieStore: PrefsCookieStore
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        probeServer = MockWebServer()
        probeServer.start()
        secure = InMemorySecureStore()
        settings = InMemorySettingsStore()
        cookieStore = PrefsCookieStore(secure)
        // 探活 base URL 与 ApiClient 同源(TestConfig);CookieCloud 服务器地址走 settings 配置
        TestConfig.mockBaseUrl = probeServer.url("/").toString().trimEnd('/')
    }

    @After
    fun tearDown() {
        TestConfig.mockBaseUrl = null
        server.shutdown()
        probeServer.shutdown()
    }

    private fun sync(): CookieCloudSync = CookieCloudSync(api, cookieStore, secure, settings)

    private fun configure(
        enabled: Boolean = true,
        serverUrl: String = server.url("/").toString().trimEnd('/'),
        uuid: String = UUID,
    ) {
        settings.putString(
            "quiz.cookieCloud",
            json.encodeToString(CloudConfig.serializer(), CloudConfig(enabled, serverUrl, uuid)),
        )
        secure.putString("cookiecloud.password", PASSWORD)
    }

    private fun localSessionCookie(value: String = "LOCAL_SESS") =
        StoredCookie("sessionId", value, "test.lanjingweike.com", "/", false, false, null, true, null)

    private fun seedSession(value: String = "LOCAL_SESS") {
        cookieStore.save(listOf(localSessionCookie(value)))
        api.session = true
    }

    /** 用本 app 的加密格式把 cookie_data JSON 包成远端 blob。 */
    private fun enqueueRemoteBlob(cookieDataJson: String) {
        val plain = """{"cookie_data":$cookieDataJson,"local_storage_data":{}}"""
        val (encrypted, type) = CookieCloudCrypto.encryptAny(plain, UUID, PASSWORD)
        server.enqueue(MockResponse().setBody("""{"encrypted":"$encrypted","crypto_type":"$type"}"""))
    }

    private fun enqueueEmptyBlob() = server.enqueue(MockResponse().setResponseCode(404))

    private fun enqueuePushDone() = server.enqueue(MockResponse().setBody("""{"action":"done"}"""))

    private val loginPage = "<!DOCTYPE html><html><body><form action=\"/login/account/login\">登录</form></body></html>"

    // ---- pushIfNeeded ----

    @Test
    fun `pushIfNeeded is no-op when not configured`() = runBlocking {
        seedSession()
        sync().pushIfNeeded()
        assertEquals(0, server.requestCount)
        assertNull(settings.getString("quiz.cookieCloud.lastPushedHash"))
    }

    @Test
    fun `pushIfNeeded is no-op without a session`() = runBlocking {
        configure()
        api.session = false
        sync().pushIfNeeded()
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `pushIfNeeded is no-op when hash unchanged`() = runBlocking {
        configure()
        seedSession()
        val s = sync()
        enqueueEmptyBlob()   // 首次 push 的远端读取(空云端)
        enqueuePushDone()
        s.pushIfNeeded()
        assertEquals(2, server.requestCount)
        s.pushIfNeeded()     // hash 未变 → 不再请求
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `pushIfNeeded uploads encrypted payload and records lastPushedHash`() = runBlocking {
        configure()
        seedSession("S1")
        enqueueEmptyBlob()
        enqueuePushDone()
        sync().pushIfNeeded()

        assertEquals("/get/uuid-1", server.takeRequest().path)
        val post = server.takeRequest()
        assertEquals("/update", post.path)
        val body = json.parseToJsonElement(post.body.readUtf8()).jsonObject
        assertEquals("uuid-1", body["uuid"]?.jsonPrimitive?.content)
        assertEquals("aes-128-cbc-fixed", body["crypto_type"]?.jsonPrimitive?.content)
        val plain = CookieCloudCrypto.decryptAny(
            body["encrypted"]!!.jsonPrimitive.content, UUID, PASSWORD, "aes-128-cbc-fixed")
        assertTrue(plain.contains("\"sessionId\""))
        assertTrue(plain.contains("\"local_storage_data\":{}"))

        // 去重 hash 已记录(sortedKeys JSON 的 SHA-256)
        val expected = cookieDataHash(listOf(localSessionCookie("S1")))
        assertEquals(expected, settings.getString("quiz.cookieCloud.lastPushedHash"))
    }

    @Test
    fun `push preserves non-lanjingweike remote cookies verbatim`() = runBlocking {
        configure()
        seedSession("S1")
        enqueueRemoteBlob("""{"example.com":[{"name":"ext","value":"v1","domain":"example.com","path":"/"}]}""")
        enqueuePushDone()
        sync().pushIfNeeded()

        server.takeRequest()   // GET
        val post = server.takeRequest()
        val body = json.parseToJsonElement(post.body.readUtf8()).jsonObject
        val plain = CookieCloudCrypto.decryptAny(
            body["encrypted"]!!.jsonPrimitive.content, UUID, PASSWORD, "aes-128-cbc-fixed")
        val payload = json.parseToJsonElement(plain).jsonObject
        val cookieData = payload["cookie_data"]!!.jsonObject
        assertTrue(cookieData.containsKey("example.com"))              // 远端非 lanjingweike 域全量保留
        assertTrue(cookieData.containsKey("test.lanjingweike.com"))    // 本地 lanjingweike 域覆盖
    }

    // ---- pullAndApplyIfNeeded ----

    @Test
    fun `pull imports cloud session when probe passes`() = runBlocking {
        configure()
        enqueueRemoteBlob(LANJING_REMOTE)
        probeServer.enqueue(MockResponse().setBody("""{"success":true}"""))

        assertTrue(sync().pullAndApplyIfNeeded())
        assertTrue(cookieStore.hasSession())
        val session = cookieStore.load().first { it.name == "sessionId" }
        assertEquals("REMOTE_SESS", session.value)
        assertEquals("test.lanjingweike.com", session.domain)
        assertEquals(1755000000L, session.expiry)   // expirationDate epoch 秒
        assertNotNull(settings.getString("quiz.cookieCloud.lastPushedHash"))
    }

    @Test
    fun `pull does not apply when probe fails`() = runBlocking {
        configure()
        enqueueRemoteBlob(LANJING_REMOTE)
        probeServer.enqueue(MockResponse().setBody(loginPage))

        assertFalse(sync().pullAndApplyIfNeeded())
        assertFalse(cookieStore.hasSession())
        assertNull(settings.getString("quiz.cookieCloud.lastPushedHash"))
    }

    @Test
    fun `pull does not apply when remote lacks sessionId`() = runBlocking {
        configure()
        enqueueRemoteBlob("""{"test.lanjingweike.com":[{"name":"other","value":"x","domain":"test.lanjingweike.com","path":"/"}]}""")

        assertFalse(sync().pullAndApplyIfNeeded())
        assertFalse(cookieStore.hasSession())
        assertEquals(0, probeServer.requestCount)   // 无 sessionId → 不探活
    }

    @Test
    fun `pull keeps local state when remote fails to decrypt`() = runBlocking {
        configure()
        seedSession("LOCAL")
        server.enqueue(MockResponse().setBody("""{"encrypted":"garbage","crypto_type":"aes-128-cbc-fixed"}"""))

        assertTrue(sync().pullAndApplyIfNeeded())   // 解密失败 → 保持现状(返回现有会话)
        assertEquals("LOCAL", cookieStore.load().first { it.name == "sessionId" }.value)
    }

    @Test
    fun `pull times out after 4s when server hangs`() = runBlocking {
        configure()
        seedSession("LOCAL")
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))

        assertTrue(sync().pullAndApplyIfNeeded())   // 4s 边界 → 返回现状
        assertEquals("LOCAL", cookieStore.load().first { it.name == "sessionId" }.value)
        assertNull(settings.getString("quiz.cookieCloud.lastPushedHash"))
    }

    @Test
    fun `pull is no-op when not configured`() = runBlocking {
        api.session = true
        assertTrue(sync().pullAndApplyIfNeeded())
        assertEquals(0, server.requestCount)
    }

    // ---- syncNow(手动双向探活)----

    @Test
    fun `syncNow returns unconfigured error`() = runBlocking {
        val result = sync().syncNow()
        assertEquals("CookieCloud 同步未配置", result.error)
        assertFalse(result.applied)
        assertFalse(result.pushed)
    }

    @Test
    fun `syncNow imports remote session when valid`() = runBlocking {
        configure()
        enqueueRemoteBlob(LANJING_REMOTE)
        probeServer.enqueue(MockResponse().setBody("""{"success":true}"""))

        val result = sync().syncNow()
        assertNull(result.error)
        assertTrue(result.applied)
        assertFalse(result.pushed)
        assertEquals("REMOTE_SESS", cookieStore.load().first { it.name == "sessionId" }.value)
        assertEquals(1, server.requestCount)   // 仅一次 GET,无推送
    }

    @Test
    fun `syncNow pushes local session when remote is invalid`() = runBlocking {
        configure()
        seedSession("LOCAL")
        enqueueRemoteBlob(LANJING_REMOTE)   // 远端存在但探活失败 → 不导入
        enqueueRemoteBlob(LANJING_REMOTE)   // pushUnconditionally 再次读取远端
        probeServer.enqueue(MockResponse().setBody(loginPage))       // 远端会话已过期
        probeServer.enqueue(MockResponse().setBody("""{"success":true}"""))   // 本地会话有效
        enqueuePushDone()

        val result = sync().syncNow()
        assertNull(result.error)
        assertFalse(result.applied)
        assertTrue(result.pushed)
        assertEquals("LOCAL", cookieStore.load().first { it.name == "sessionId" }.value)
        assertEquals(3, server.requestCount)   // GET + GET + POST
    }

    @Test
    fun `syncNow surfaces server errors`() = runBlocking {
        configure()
        server.enqueue(MockResponse().setResponseCode(500))

        val result = sync().syncNow()
        assertNotNull(result.error)
        assertFalse(result.applied)
        assertFalse(result.pushed)
    }

    // ---- cookie_data 构造/解析/合并/去重 hash(spec §3.4)----

    @Test
    fun `import applies defaults and drops session flag`() {
        val remote = json.parseToJsonElement("""{"test.lanjingweike.com":[
            {"name":"a","value":"1","domain":"test.lanjingweike.com","expirationDate":1755000000,"session":true,"sameSite":"none"},
            {"name":"b","value":"2","domain":"test.lanjingweike.com"}
        ]}""").jsonObject
        val cookies = cookiesFromRemote(remote)
        val a = cookies.first { it.name == "a" }
        assertEquals("test.lanjingweike.com", a.domain)
        assertEquals("/", a.path)              // path 缺省 "/"
        assertTrue(a.secure)                   // secure 缺省 true
        assertEquals(1755000000L, a.expiry)    // expirationDate epoch 秒
        assertFalse(a.sessionOnly)             // session 标志导入时丢弃(iOS 同)
        assertNull(a.sameSite)                 // sameSite "none" 不保留
        val b = cookies.first { it.name == "b" }
        assertEquals("/", b.path)
        assertTrue(b.secure)
        assertNull(b.expiry)
    }

    @Test
    fun `import ignores non-lanjingweike domains`() {
        val remote = json.parseToJsonElement(
            """{"example.com":[{"name":"sessionId","value":"X","domain":"example.com","path":"/"}]}""",
        ).jsonObject
        assertTrue(cookiesFromRemote(remote).isEmpty())
    }

    @Test
    fun `export writes spec fields and omits sameSite none`() {
        val local = listOf(
            StoredCookie("sessionId", "S", "test.lanjingweike.com", "/", true, false, 1755000000L, false, "lax"),
            StoredCookie("sess", "V", "test.lanjingweike.com", "/", true, false, null, true, "none"),
        )
        val out = Json.encodeToString(JsonElement.serializer(), cookieDataFromLocal(local))
        assertTrue(out.contains("\"expirationDate\":1755000000"))
        assertTrue(out.contains("\"sameSite\":\"lax\""))
        assertTrue(out.contains("\"session\":true"))          // 仅会话 cookie 写 session
        assertFalse(out.contains("\"sameSite\":\"none\""))    // "none" 永不写入
    }

    @Test
    fun `hash is sha256 over sorted-key json of cookie data`() {
        val expected = Hashers.sha256Hex(
            """{"test.lanjingweike.com":[{"domain":"test.lanjingweike.com","name":"sessionId","path":"/","secure":false,"session":true,"value":"S1"}]}""",
        )
        assertEquals(expected, cookieDataHash(listOf(localSessionCookie("S1"))))
    }

    @Test
    fun `merge keeps non-lanjingweike remote domains and replaces lanjingweike`() {
        val remote = json.parseToJsonElement("""{"example.com":[{"name":"e","value":"1","domain":"example.com","path":"/"}],"test.lanjingweike.com":[{"name":"old","value":"x","domain":"test.lanjingweike.com","path":"/"}]}""").jsonObject
        val ours = json.parseToJsonElement("""{"test.lanjingweike.com":[{"name":"new","value":"y","domain":"test.lanjingweike.com","path":"/"}]}""").jsonObject
        val merged = mergeCookieData(remote, ours)
        assertTrue(merged.containsKey("example.com"))          // 非 lanjingweike 域全量保留
        val lanjing = merged["test.lanjingweike.com"]!!.jsonArray
        assertEquals(1, lanjing.size)
        assertEquals("new", lanjing.first().jsonObject["name"]?.jsonPrimitive?.content)
    }

    companion object {
        const val UUID = "uuid-1"
        const val PASSWORD = "pass-1"
        private val LANJING_REMOTE = """{
            "test.lanjingweike.com": [
                {"name":"sessionId","value":"REMOTE_SESS","domain":"test.lanjingweike.com","path":"/","secure":true,"expirationDate":1755000000,"httpOnly":true}
            ]
        }"""
    }
}
