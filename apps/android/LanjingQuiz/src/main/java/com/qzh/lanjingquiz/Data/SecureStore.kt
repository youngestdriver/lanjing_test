package com.qzh.lanjingquiz.Data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** 安全存储接口语义(JVM 单测用 InMemorySecureStore 替代,供后续任务测试复用)。 */
interface SecureStoreLike {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun remove(key: String)
}

/** EncryptedSharedPreferences("secure"),对应 iOS Keychain(service com.qzh.lanjingquiz)。 */
class SecureStore(context: Context) : SecureStoreLike {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "secure",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override fun getString(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String) { prefs.edit().putString(key, value).apply() }
    override fun remove(key: String) { prefs.edit().remove(key).apply() }
}
