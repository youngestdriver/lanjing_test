package com.qzh.lanjingquiz.Data

/** JVM 单测用内存实现,与 SecureStore 相同接口语义(供后续任务测试复用)。 */
class InMemorySecureStore : SecureStoreLike {
    private val map = mutableMapOf<String, String>()
    override fun getString(key: String): String? = map[key]
    override fun putString(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
}

/** JVM 单测用内存实现,与 SettingsStore 相同接口语义(供后续任务测试复用)。 */
class InMemorySettingsStore : SettingsStore {
    private val strings = mutableMapOf<String, String>()
    private val booleans = mutableMapOf<String, Boolean>()

    override fun getString(key: String, default: String?): String? = strings[key] ?: default
    override fun putString(key: String, value: String) { strings[key] = value }
    override fun getBoolean(key: String, default: Boolean): Boolean = booleans[key] ?: default
    override fun putBoolean(key: String, value: Boolean) { booleans[key] = value }
    override fun remove(key: String) {
        strings.remove(key)
        booleans.remove(key)
    }
}
