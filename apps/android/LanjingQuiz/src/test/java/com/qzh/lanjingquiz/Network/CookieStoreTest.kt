package com.qzh.lanjingquiz.Network

import com.qzh.lanjingquiz.Data.InMemorySecureStore
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CookieStoreTest {
    @Test
    fun `PrefsCookieStore JSON round trip preserves all fields`() {
        val store = PrefsCookieStore(InMemorySecureStore())
        val cookies = listOf(
            StoredCookie("sessionId", "S1", "test.lanjingweike.com", "/",
                secure = true, httpOnly = true, expiry = 1_700_000_000L, sessionOnly = false, sameSite = "lax"),
            StoredCookie("JSESSIONID", "J1", ".lanjingweike.com", "/",
                secure = false, httpOnly = true, expiry = null, sessionOnly = true, sameSite = null),
        )
        store.save(cookies)
        assertEquals(cookies, store.load())
    }

    @Test
    fun `hasSession checks for sessionId cookie`() {
        val store = PrefsCookieStore(InMemorySecureStore())
        assertFalse(store.hasSession())
        store.save(listOf(StoredCookie("sessionId", "S1", "test.lanjingweike.com", "/", false, false, null, true, null)))
        assertTrue(store.hasSession())
        store.save(listOf(StoredCookie("JSESSIONID", "J1", "test.lanjingweike.com", "/", false, false, null, true, null)))
        assertFalse(store.hasSession())
    }

    @Test
    fun `headerString joins name value pairs with semicolon space`() {
        val store = PrefsCookieStore(InMemorySecureStore())
        store.save(listOf(
            StoredCookie("JSESSIONID", "js1", "test.lanjingweike.com", "/", false, false, null, true, null),
            StoredCookie("sessionId", "S1", "test.lanjingweike.com", "/", false, false, null, true, null),
        ))
        assertEquals("JSESSIONID=js1; sessionId=S1", store.headerString())
    }

    @Test
    fun `clear removes all cookies`() {
        val store = PrefsCookieStore(InMemorySecureStore())
        store.save(listOf(StoredCookie("sessionId", "S1", "test.lanjingweike.com", "/", false, false, null, true, null)))
        store.clear()
        assertTrue(store.load().isEmpty())
        assertFalse(store.hasSession())
    }

    @Test
    fun `PersistentCookieJar round trips cookies for mock host`() {
        val jar = PersistentCookieJar(PrefsCookieStore(InMemorySecureStore()))
        val url = "http://127.0.0.1:8080/exam".toHttpUrl()
        val cookie = Cookie.Builder()
            .domain("127.0.0.1").path("/").name("sessionId").value("abc").build()
        jar.saveFromResponse(url, listOf(cookie))
        val loaded = jar.loadForRequest(url)
        assertEquals("abc", loaded.firstOrNull { it.name == "sessionId" }?.value)
        assertTrue(jar.hasSession())
    }

    @Test
    fun `loadForRequest returns every cookie on the same domain`() {
        val jar = PersistentCookieJar(PrefsCookieStore(InMemorySecureStore()))
        val url = "http://127.0.0.1:8080/exam".toHttpUrl()
        // 与 iOS testKSXCIDSyncsLikeAnyOtherCookie 相同的三 cookie 会话形态
        jar.saveFromResponse(url, listOf(cookie("JSESSIONID", "js1")))
        jar.saveFromResponse(url, listOf(cookie("sessionId", "abc")))
        jar.saveFromResponse(url, listOf(cookie("KSX_CID", "1")))
        val names = jar.loadForRequest(url).map { "${it.name}=${it.value}" }.sorted()
        assertEquals(listOf("JSESSIONID=js1", "KSX_CID=1", "sessionId=abc"), names)
    }

    @Test
    fun `repeated Set-Cookie of the same name does not duplicate`() {
        val jar = PersistentCookieJar(PrefsCookieStore(InMemorySecureStore()))
        val url = "http://127.0.0.1:8080/exam".toHttpUrl()
        jar.saveFromResponse(url, listOf(cookie("sessionId", "old")))
        jar.saveFromResponse(url, listOf(cookie("sessionId", "new")))
        assertEquals(1, jar.loadForRequest(url).count { it.name == "sessionId" })
        assertEquals("sessionId=new", jar.headerStringForBase())
    }

    @Test
    fun `headerStringForBase reflects the merged cookie set`() {
        val jar = PersistentCookieJar(PrefsCookieStore(InMemorySecureStore()))
        val url = "http://127.0.0.1:8080/exam".toHttpUrl()
        jar.saveFromResponse(url, listOf(cookie("JSESSIONID", "js1")))
        jar.saveFromResponse(url, listOf(cookie("sessionId", "abc")))
        assertEquals("JSESSIONID=js1; sessionId=abc", jar.headerStringForBase())
    }

    private fun cookie(name: String, value: String) = Cookie.Builder()
        .domain("127.0.0.1").path("/").name(name).value(value).build()
}
