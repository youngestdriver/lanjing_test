package com.qzh.lanjingquiz.Network

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * OkHttp CookieJar:响应后合并写回 store,请求前从 store 刷新。
 * 与 iOS 一致,一律全存(不按域名过滤)。
 */
class PersistentCookieJar(private val store: CookieStore) : CookieJar {
    private val cache = LinkedHashMap<String, List<Cookie>>()

    fun headerStringForBase(): String = store.headerString()
    fun hasCookie(name: String): Boolean = store.load().any { it.name == name }
    fun hasSession(): Boolean = store.hasSession()
    fun clear() = store.clear()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cache[url.host] = cookies
        val incoming = cookies.map { it.toStored() }
        // 同名同域同路径去重:新 cookie 覆盖旧 cookie(iOS HTTPCookieStorage 语义)
        val merged = store.load()
            .filter { old -> incoming.none { it.name == old.name && it.domain == old.domain && it.path == old.path } } + incoming
        store.save(merged)
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        // 每域聚合成列表再写入缓存:同一域名的多个 cookie 全部保留
        store.load()
            .filter { it.expiry == null || it.expiry * 1000 > now }
            .groupBy { it.domain }
            .forEach { (domain, cookies) -> cache[domain] = cookies.map { it.toOkHttp(url) } }
        return cache.values.flatten()
            .filter { it.matches(url) && (it.expiresAt == Long.MAX_VALUE || it.expiresAt > now) }
    }

    private fun Cookie.matches(url: HttpUrl): Boolean =
        (url.host.endsWith(domain.removePrefix(".")) || domain.removePrefix(".") in url.host) && url.encodedPath.startsWith(path)

    private fun Cookie.toStored() = StoredCookie(
        name, value, domain.removePrefix("."), path, secure, httpOnly,
        expiry = if (expiresAt == Long.MAX_VALUE) null else expiresAt / 1000,
        sessionOnly = expiresAt == Long.MAX_VALUE, sameSite = null,
    )
    private fun StoredCookie.toOkHttp(url: HttpUrl) = Cookie.Builder()
        .domain(domain).path(path).name(name).value(value)
        .apply { if (secure) this.secure(); if (httpOnly) this.httpOnly() }
        .apply { if (sessionOnly || expiry == null) this.expiresAt(Long.MAX_VALUE) else this.expiresAt(expiry * 1000) }
        .build()
}
