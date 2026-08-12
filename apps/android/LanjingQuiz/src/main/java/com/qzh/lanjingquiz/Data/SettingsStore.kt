package com.qzh.lanjingquiz.Data

import android.content.Context

/** 普通明文 SharedPreferences("settings"),键名与 iOS UserDefaults 逐字保留。 */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun getString(key: String, default: String? = null): String? = prefs.getString(key, default)
    fun putString(key: String, value: String) { prefs.edit().putString(key, value).apply() }
    fun getBoolean(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    fun putBoolean(key: String, value: Boolean) { prefs.edit().putBoolean(key, value).apply() }
    fun remove(key: String) { prefs.edit().remove(key).apply() }
}
