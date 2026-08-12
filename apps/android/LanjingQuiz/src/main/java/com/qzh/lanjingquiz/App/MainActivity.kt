package com.qzh.lanjingquiz.App

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.qzh.lanjingquiz.BuildConfig
import com.qzh.lanjingquiz.Network.TestConfig
import com.qzh.lanjingquiz.UI.AppRoot
import com.qzh.lanjingquiz.UI.LanjingQuizTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject lateinit var appState: AppState

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 仅 debug 构建接受 mock base URL intent extra(生产路径不受影响;Hilt 单例 ApiClient
        // 在首次注入时经 TestConfig.effectiveBaseUrl 取用,故此处先于 setContent 写入)
        if (BuildConfig.DEBUG) {
            intent.getStringExtra(TestConfig.EXTRA_MOCK_BASE_URL)?.let { TestConfig.mockBaseUrl = it }
        }
        enableEdgeToEdge()
        setContent {
            // 主题联动:AppState.theme 决定 LanjingQuizTheme.darkTheme(全 App 同一单例)
            val theme by appState.theme.collectAsState()
            LanjingQuizTheme(darkTheme = when (theme) {
                ThemeMode.Light -> false
                ThemeMode.Dark -> true
                ThemeMode.System -> isSystemInDarkTheme()
            }) {
                AppRoot(appState)
            }
        }
    }
}
