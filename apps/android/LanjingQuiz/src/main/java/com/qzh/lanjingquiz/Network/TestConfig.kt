package com.qzh.lanjingquiz.Network

/**
 * 测试 base URL 注入点(Resolution 3 的实现):
 * 仪器化 UI 测试用 Intent extra("mockBaseUrl") 在 MainActivity.onCreate 写入(BuildConfig.DEBUG 守卫),
 * 全 App(ApiClient + RichWebView)统一经 [effectiveBaseUrl] 取用 —— 生产构建恒为 DEFAULT_BASE_URL,不受影响。
 */
object TestConfig {
    const val EXTRA_MOCK_BASE_URL = "mockBaseUrl"

    @Volatile
    var mockBaseUrl: String? = null

    fun effectiveBaseUrl(): String = mockBaseUrl ?: ApiClient.DEFAULT_BASE_URL
}
