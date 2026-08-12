package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Data.SecureStoreLike
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Network.CookieCloudClient
import com.qzh.lanjingquiz.Network.CookieCloudException
import com.qzh.lanjingquiz.Network.CookieStore
import com.qzh.lanjingquiz.Network.StoredCookie
import com.qzh.lanjingquiz.Network.UpstreamApi
import com.qzh.lanjingquiz.Support.CookieCloudCrypto
import com.qzh.lanjingquiz.Support.Hashers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.TreeMap
import javax.inject.Inject

/** CookieCloud 配置(非机密字段);键名与 iOS UserDefaults 逐字一致(quiz.cookieCloud)。 */
@Serializable
data class CloudConfig(val enabled: Boolean, val server: String, val uuid: String) {
    companion object {
        val EMPTY = CloudConfig(false, "", "")
    }
}

// ---- cookie_data JSON 构造/解析/合并(iOS CookieCloudConversion 移植,逐字 spec §3.4)----

internal const val LANJING_DOMAIN_MARKER = "lanjingweike.com"

/**
 * [StoredCookie] → {domain: [cookie 字典]}。字段:name/value/domain/path/secure 恒写;
 * expirationDate 仅非会话 cookie 有(epoch 秒);session 仅会话 cookie;sameSite "none" 永不写入。
 * 使用 TreeMap 逐层排序,产出 sortedKeys JSON(iOS JSONSerialization [.sortedKeys] 语义)供去重 hash。
 */
internal fun cookieDataFromLocal(cookies: List<StoredCookie>): JsonObject {
    val grouped = TreeMap<String, MutableList<JsonObject>>()
    for (cookie in cookies) {
        val dict = TreeMap<String, JsonElement>().apply {
            this["name"] = JsonPrimitive(cookie.name)
            this["value"] = JsonPrimitive(cookie.value)
            this["domain"] = JsonPrimitive(cookie.domain)
            this["path"] = JsonPrimitive(cookie.path)
            this["secure"] = JsonPrimitive(cookie.secure)
            cookie.expiry?.let { this["expirationDate"] = JsonPrimitive(it) }
            if (cookie.sessionOnly) this["session"] = JsonPrimitive(true)
            if (!cookie.sameSite.isNullOrEmpty() && !cookie.sameSite.equals("none", ignoreCase = true)) {
                this["sameSite"] = JsonPrimitive(cookie.sameSite.lowercase())
            }
        }
        grouped.getOrPut(cookie.domain) { mutableListOf() }.add(JsonObject(dict))
    }
    return JsonObject(TreeMap<String, JsonElement>().apply {
        grouped.forEach { (domain, list) -> this[domain] = JsonArray(list) }
    })
}

/**
 * 远端 cookie_data → [StoredCookie]。仅 domain 含 "lanjingweike.com" 的 cookie 导入;
 * secure 缺省 true、path 缺省 "/";httpOnly/session 导入时丢弃(iOS SDK 无对应属性,注释一致)。
 */
internal fun cookiesFromRemote(cookieData: JsonObject?): List<StoredCookie> {
    val result = mutableListOf<StoredCookie>()
    val root = cookieData ?: return result
    for ((domain, cookies) in root) {
        if (!domain.contains(LANJING_DOMAIN_MARKER)) continue
        val array = cookies as? JsonArray ?: continue
        for (element in array) {
            val c = element as? JsonObject ?: continue
            val name = c["name"]?.jsonPrimitive?.contentOrNull ?: continue
            if (name.isEmpty()) continue
            val value = c["value"]?.jsonPrimitive?.contentOrNull ?: continue
            val cookieDomain = c["domain"]?.jsonPrimitive?.contentOrNull ?: domain
            val path = c["path"]?.jsonPrimitive?.contentOrNull ?: "/"
            val secure = c["secure"]?.jsonPrimitive?.booleanOrNull ?: true
            val expiry = c["expirationDate"]?.jsonPrimitive?.let {
                if (it.isString) it.content.toDoubleOrNull()?.toLong()
                else it.longOrNull ?: it.doubleOrNull?.toLong()
            }
            val sameSiteRaw = c["sameSite"]?.jsonPrimitive?.contentOrNull?.lowercase()
            val sameSite = if (sameSiteRaw == "lax" || sameSiteRaw == "strict") sameSiteRaw else null
            result += StoredCookie(
                name = name, value = value, domain = cookieDomain, path = path,
                secure = secure, httpOnly = false, expiry = expiry, sessionOnly = false, sameSite = sameSite,
            )
        }
    }
    return result
}

/** 推送 payload 合并:远端非 lanjingweike 域全量保留,本地(ours)覆盖远端 lanjingweike 域。 */
internal fun mergeCookieData(remote: JsonObject, ours: JsonObject): JsonObject =
    JsonObject(TreeMap<String, JsonElement>().apply {
        for ((domain, cookies) in remote) {
            if (!domain.contains(LANJING_DOMAIN_MARKER)) this[domain] = cookies
        }
        putAll(ours)
    })

/** 上传 payload:{"cookie_data": ..., "local_storage_data": {}}。 */
internal fun uploadPayload(cookieData: JsonObject): JsonObject =
    JsonObject(TreeMap<String, JsonElement>().apply {
        this["cookie_data"] = cookieData
        this["local_storage_data"] = JsonObject(TreeMap())
    })

/** 去重 hash = cookieData 的 sortedKeys JSON 的 SHA-256 hex(iOS Hashing.sha256Hex 同)。 */
internal fun cookieDataHash(cookies: List<StoredCookie>): String =
    Hashers.sha256Hex(Json.encodeToString(JsonElement.serializer(), cookieDataFromLocal(cookies)))

/**
 * CookieCloud 协调器(iOS CookieCloudSync 移植):登录后推送(去重 hash)、启动拉取
 * (4s 边界,远端有效 + 探活通过才 apply)、我的页手动双向探活同步。
 * 会话真值 = api.hasSession(与 T2 路由判定同源);cookie 读写经 CookieStore。
 */
class CookieCloudSync @Inject constructor(
    private val api: UpstreamApi,
    private val cookieStore: CookieStore,
    private val secureStore: SecureStoreLike,
    private val settings: SettingsStore,
) {
    /** 手动同步结果,我的页渲染:"同步完成" + 已导入云端会话/已上传本地会话(逗号连接)。 */
    data class SyncResult(val error: String?, val applied: Boolean, val pushed: Boolean)

    private val json = Json { ignoreUnknownKeys = true }
    private var lastPushedHash: String? = settings.getString(KEY_LAST_PUSHED_HASH)

    val isConfigured: Boolean
        get() {
            val c = config
            return c.enabled && c.server.isNotEmpty() && c.uuid.isNotEmpty() && password.isNotEmpty()
        }

    /** 配置(每次读取设置,UI 修改即时生效)。 */
    val config: CloudConfig
        get() = settings.getString(KEY_CONFIG)?.let {
            runCatching { json.decodeFromString<CloudConfig>(it) }.getOrNull()
        } ?: CloudConfig.EMPTY

    fun saveConfig(config: CloudConfig) {
        settings.putString(KEY_CONFIG, json.encodeToString(CloudConfig.serializer(), config))
    }

    fun loadPassword(): String = secureStore.getString(KEY_PASSWORD) ?: ""
    fun savePassword(password: String) { secureStore.putString(KEY_PASSWORD, password) }

    private val password: String get() = loadPassword()

    private val lanjingCookies: List<StoredCookie>
        get() = cookieStore.load().filter { it.domain.contains(LANJING_DOMAIN_MARKER) }

    private val currentJarHash: String get() = cookieDataHash(lanjingCookies)

    private fun jarString(cookies: List<StoredCookie>): String =
        cookies.joinToString("; ") { "${it.name}=${it.value}" }

    /** 拉取并解密远端 blob;服务器无 blob(null)或失败抛异常。 */
    private suspend fun fetchAndDecrypt(): JsonObject? {
        val c = config
        val blob = CookieCloudClient(c.server).get(c.uuid) ?: return null
        val plain = CookieCloudCrypto.decryptAny(blob.first, c.uuid, password, blob.second)
        val root = json.parseToJsonElement(plain) as? JsonObject
            ?: throw CookieCloudException("cookiecloud: invalid plaintext")
        return root["cookie_data"] as? JsonObject ?: JsonObject(TreeMap())
    }

    /** 导入:先删本地全部 lanjingweike cookie,再合并远端(非 lanjingweike 本地 cookie 保留),落盘并更新 hash。 */
    private fun apply(imported: List<StoredCookie>) {
        val kept = cookieStore.load().filterNot { it.domain.contains(LANJING_DOMAIN_MARKER) }
        cookieStore.save(kept + imported)
        updateLastPushedHash()
    }

    private fun updateLastPushedHash() {
        val hash = currentJarHash
        lastPushedHash = hash
        settings.putString(KEY_LAST_PUSHED_HASH, hash)
    }

    /** 无条件推送:远端非 lanjingweike 域保留,本地 lanjingweike 覆盖,加密后 update。 */
    private suspend fun pushUnconditionally() {
        val c = config
        val ours = cookieDataFromLocal(lanjingCookies)
        val remote = runCatching { fetchAndDecrypt() }.getOrNull() ?: JsonObject(TreeMap())
        val merged = mergeCookieData(remote, ours)
        val plain = json.encodeToString(JsonElement.serializer(), uploadPayload(merged))
        val (encrypted, type) = CookieCloudCrypto.encryptAny(plain, c.uuid, password)
        CookieCloudClient(c.server).update(c.uuid, encrypted, type)
        updateLastPushedHash()
    }

    /** 启动拉取(4s 硬边界):远端存在 + 含 sessionId + hash 不同 + 探活通过才 apply;任何异常 → 保持现状。 */
    suspend fun pullAndApplyIfNeeded(): Boolean = withTimeoutOrNull(PULL_TIMEOUT_MS) {
        if (!isConfigured) return@withTimeoutOrNull api.hasSession()
        try {
            val remote = fetchAndDecrypt()
            val cookies = cookiesFromRemote(remote)
            if (cookies.any { it.name == "sessionId" } &&
                cookieDataHash(cookies) != lastPushedHash &&
                CookieCloudClient(config.server).probeSession(jarString(cookies))
            ) {
                apply(cookies)
                true
            } else {
                api.hasSession()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            api.hasSession()
        }
    } ?: api.hasSession()

    /** 登录后推送:未配置/无会话/hash 未变 → no-op;失败吞掉(fire-and-forget,下次再推)。 */
    suspend fun pushIfNeeded() {
        if (!isConfigured || !api.hasSession()) return
        val hash = currentJarHash
        if (hash == lastPushedHash) return
        try {
            pushUnconditionally()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 保持本地 hash 不变,下次调用重试
        }
    }

    /** 手动同步:双向探活 —— 云端会话有效则导入,本地会话有效且分叉则推送。 */
    suspend fun syncNow(): SyncResult {
        if (!isConfigured) return SyncResult("CookieCloud 同步未配置", false, false)
        return try {
            var applied = false
            var pushed = false
            val remote = fetchAndDecrypt()
            val cookies = cookiesFromRemote(remote)
            if (cookies.any { it.name == "sessionId" } &&
                cookieDataHash(cookies) != lastPushedHash &&
                CookieCloudClient(config.server).probeSession(jarString(cookies))
            ) {
                apply(cookies)
                applied = true
            }
            // 推送仅在(可能刚导入的)本地 jar 分叉于上次写入且探活仍有效时发生
            if (api.hasSession() && currentJarHash != lastPushedHash &&
                CookieCloudClient(config.server).probeSession(jarString(lanjingCookies))
            ) {
                pushUnconditionally()
                pushed = true
            }
            SyncResult(null, applied, pushed)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            SyncResult(e.message ?: "同步失败", false, false)
        }
    }

    companion object {
        const val KEY_CONFIG = "quiz.cookieCloud"
        const val KEY_LAST_PUSHED_HASH = "quiz.cookieCloud.lastPushedHash"
        const val KEY_PASSWORD = "cookiecloud.password"
        private const val PULL_TIMEOUT_MS = 4000L
    }
}
