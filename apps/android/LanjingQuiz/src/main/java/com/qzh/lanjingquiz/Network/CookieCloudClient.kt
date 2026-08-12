package com.qzh.lanjingquiz.Network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** CookieCloud 服务器/同步错误(与上游 ApiException 分离;fail-closed 语义)。 */
class CookieCloudException(message: String) : Exception(message)

/**
 * 自建 CookieCloud 服务器客户端(iOS CookieCloudClient 移植):
 * POST {server}/update、GET {server}/get/{uuid}、上游探活三个端点。
 *
 * 使用独立 OkHttpClient:**不带** CookieJar(云端流量绝不进入 lanjingweike cookie jar,
 * 探活 jar 显式经 Cookie 头发送)且不缓存;超时 10s。server 取自设置(config)每次构造;
 * 探活的 base URL 与 ApiClient 同源(TestConfig —— 生产恒为 DEFAULT_BASE_URL),不是云端地址。
 */
class CookieCloudClient(
    private val server: String,
    private val baseUrlProvider: () -> String = { TestConfig.effectiveBaseUrl() },
) {
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .cache(null)
        .build()

    private val json = Json { ignoreUnknownKeys = true }
    private val jsonMedia = "application/json".toMediaType()
    private val formMedia = "application/x-www-form-urlencoded; charset=UTF-8".toMediaType()

    /** POST {server}/update — 覆盖该 uuid 的加密 blob;成功 iff HTTP<300 且 {"action":"done"}。 */
    suspend fun update(uuid: String, encrypted: String, cryptoType: String = "aes-128-cbc-fixed") =
        withContext(Dispatchers.IO) {
            val body = buildJsonObject {
                put("uuid", uuid)
                put("encrypted", encrypted)
                put("crypto_type", cryptoType)
            }
            val request = Request.Builder()
                .url("${server.trimEnd('/')}/update")
                .header("Content-Type", "application/json")
                .post(json.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonMedia))
                .build()
            http.newCall(request).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (resp.code >= 300) throw CookieCloudException("cookiecloud: upload was not acknowledged")
                val action = runCatching { json.parseToJsonElement(text).jsonObject["action"]?.jsonPrimitive?.content }
                    .getOrNull()
                if (action != "done") throw CookieCloudException("cookiecloud: upload was not acknowledged")
            }
        }

    /** GET {server}/get/{uuid};404 = 空云端(null)。其他失败抛异常。返回 encrypted + cryptoType。 */
    suspend fun get(uuid: String): Pair<String, String?>? = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("${server.trimEnd('/')}/get/$uuid")
            .build()
        http.newCall(request).execute().use { resp ->
            if (resp.code == 404) return@use null
            if (resp.code !in 200..299) throw CookieCloudException("cookiecloud: download failed with status ${resp.code}")
            val obj = runCatching { json.parseToJsonElement(resp.body?.string().orEmpty()).jsonObject }.getOrNull()
                ?: throw CookieCloudException("cookiecloud: malformed server response")
            val encrypted = obj["encrypted"]?.jsonPrimitive?.content
                ?: throw CookieCloudException("cookiecloud: malformed server response")
            val cryptoType = obj["crypto_type"]?.jsonPrimitive?.content
            encrypted to cryptoType
        }
    }

    /**
     * 上游探活:POST {baseURL}/exam/current_exam_list,body page=1&pageSize=1,
     * 候选 jar 经 Cookie 头显式发送(独立 client 无 cookie 持久化)。有效性 = 过期三规则
     * 未命中;jar 无 sessionId= 或任何网络错误 → false(保守:绝不采纳未验证的会话)。
     */
    suspend fun probeSession(jarHeader: String): Boolean {
        if (!jarHeader.contains("sessionId=")) return false
        val base = baseUrlProvider().trimEnd('/')
        return try {
            val request = Request.Builder()
                .url("$base/exam/current_exam_list")
                .header("User-Agent", ApiClient.USER_AGENT)
                .header("X-Requested-With", "XMLHttpRequest")
                .header("Origin", base)
                .header("Referer", "$base/exam")
                .header("Accept", "application/json, text/javascript, */*; q=0.01")
                .header("Cookie", jarHeader)
                .post("page=1&pageSize=1".toRequestBody(formMedia))
                .build()
            withContext(Dispatchers.IO) {
                http.newCall(request).execute().use { resp ->
                    val text = resp.body?.string().orEmpty()
                    !detectSessionExpiry(text)
                }
            }
        } catch (e: Exception) {
            false
        }
    }
}
