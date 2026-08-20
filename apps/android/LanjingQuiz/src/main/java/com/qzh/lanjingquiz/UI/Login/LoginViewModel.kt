package com.qzh.lanjingquiz.UI.Login

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.UpstreamApi
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class LoginViewModel @Inject constructor(
    private val api: UpstreamApi,
) : ViewModel() {

    val phone = MutableStateFlow("")
    val password = MutableStateFlow("")

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _isSubmitting = MutableStateFlow(false)
    val isSubmitting: StateFlow<Boolean> = _isSubmitting.asStateFlow()

    val showPassword = MutableStateFlow(false)
    val agreedToTerms = MutableStateFlow(true)   // iOS 缺省已勾选

    /** AppRoot 注入(绑到 AppState 同一实例):登录成功 → appState.finishLogin()。 */
    var onFinished: () -> Unit = {}

    /** AppRoot 注入:会话过期/未登录 → appState.handleSessionExpiry()(清会话+通知+回登录页)。 */
    var onSessionError: () -> Unit = {}

    fun submit() {
        // 手机号归一化:去全部空白(含不间断空格)
        val normalized = phone.value.filterNot { it.isWhitespace() }
        if (normalized.isEmpty() || password.value.isEmpty()) {
            _errorMessage.value = "请输入手机号和密码"
            return
        }
        viewModelScope.launch {
            _isSubmitting.value = true
            try {
                api.login(normalized, password.value)
                _errorMessage.value = null
                onFinished()
            } catch (e: ApiException) {
                if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
                    // 会话级错误:由 AppState 统一处理(清会话+通知+回登录页),不展示错误文案
                    onSessionError()
                } else {
                    _errorMessage.value = e.message
                }
            } finally {
                _isSubmitting.value = false
            }
        }
    }
}
