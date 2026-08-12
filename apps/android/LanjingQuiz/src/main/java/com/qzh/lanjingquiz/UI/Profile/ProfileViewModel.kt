package com.qzh.lanjingquiz.UI.Profile

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.Domain.CloudConfig
import com.qzh.lanjingquiz.Domain.CookieCloudSync
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * 我的页 ViewModel:CookieCloud 配置字段(服务器地址/UUID/密码)的加载与即时持久化
 * (配置 JSON → SettingsStore quiz.cookieCloud,密码 → SecureStore cookiecloud.password),
 * 以及"立即同步"的执行与状态文案组装。外观/答题设置/退出登录直接走 AppState。
 */
@HiltViewModel
class ProfileViewModel @Inject constructor(
    private val appState: AppState,
    private val sync: CookieCloudSync,
) : ViewModel() {

    val cloudEnabled = MutableStateFlow(false)
    val cloudServer = MutableStateFlow("")
    val cloudUuid = MutableStateFlow("")
    val cloudPassword = MutableStateFlow("")

    private val _syncStatus = MutableStateFlow<String?>(null)
    val syncStatus: StateFlow<String?> = _syncStatus.asStateFlow()

    private val _isSyncing = MutableStateFlow(false)
    val isSyncing: StateFlow<Boolean> = _isSyncing.asStateFlow()

    /** 立即同步可用条件:enabled && 服务器地址/UUID/密码均非空。 */
    val isConfigured: Boolean
        get() = cloudEnabled.value && cloudServer.value.isNotEmpty() &&
            cloudUuid.value.isNotEmpty() && cloudPassword.value.isNotEmpty()

    init {
        val config = sync.config
        cloudEnabled.value = config.enabled
        cloudServer.value = config.server
        cloudUuid.value = config.uuid
        cloudPassword.value = sync.loadPassword()
    }

    fun setCloudEnabled(enabled: Boolean) { cloudEnabled.value = enabled; persistConfig() }
    fun setCloudServer(server: String) { cloudServer.value = server; persistConfig() }
    fun setCloudUuid(uuid: String) { cloudUuid.value = uuid; persistConfig() }
    fun setCloudPassword(password: String) { cloudPassword.value = password; sync.savePassword(password) }

    private fun persistConfig() {
        sync.saveConfig(CloudConfig(cloudEnabled.value, cloudServer.value, cloudUuid.value))
    }

    /** 立即同步:状态文案 = 同步完成 + 已导入云端会话/已上传本地会话(逗号连接);错误 = 同步失败：{原因}。 */
    fun syncNow() {
        viewModelScope.launch {
            _isSyncing.value = true
            val result = appState.syncNow()
            _syncStatus.value = if (result.error != null) {
                "同步失败：${result.error}"
            } else {
                buildList {
                    add("同步完成")
                    if (result.applied) add("已导入云端会话")
                    if (result.pushed) add("已上传本地会话")
                }.joinToString("，")
            }
            _isSyncing.value = false
        }
    }
}
