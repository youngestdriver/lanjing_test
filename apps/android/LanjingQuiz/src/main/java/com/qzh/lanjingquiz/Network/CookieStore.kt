package com.qzh.lanjingquiz.Network

import com.qzh.lanjingquiz.Data.SecureStoreLike
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

@Serializable
data class StoredCookie(
    val name: String,
    val value: String,
    val domain: String,
    val path: String,
    val secure: Boolean,
    val httpOnly: Boolean,
    val expiry: Long? = null,
    val sessionOnly: Boolean = false,
    val sameSite: String? = null,
)

interface CookieStore {
    fun load(): List<StoredCookie>
    fun save(cookies: List<StoredCookie>)
    fun clear()
    fun hasSession(): Boolean   // 存在 name == "sessionId" 的 cookie
    fun headerString(): String  // "name=value; name2=value2"
}

class PrefsCookieStore(private val secureStore: SecureStoreLike) : CookieStore {
    private val json = Json { ignoreUnknownKeys = true }
    override fun load(): List<StoredCookie> =
        secureStore.getString("cookies")?.let { json.decodeFromString<List<StoredCookie>>(it) } ?: emptyList()
    override fun save(cookies: List<StoredCookie>) =
        secureStore.putString("cookies", json.encodeToString(ListSerializer(StoredCookie.serializer()), cookies))
    override fun clear() = secureStore.remove("cookies")
    override fun hasSession(): Boolean = load().any { it.name == "sessionId" }
    override fun headerString(): String =
        load().joinToString("; ") { "${it.name}=${it.value}" }
}
