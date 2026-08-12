package com.qzh.lanjingquiz.App

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.UI.AppRoot
import com.qzh.lanjingquiz.UI.LanjingQuizTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            // 主题联动:AppState.theme 决定 LanjingQuizTheme.darkTheme(与 AppRoot 同实例)
            val appState: AppState = hiltViewModel()
            val theme by appState.theme.collectAsState()
            LanjingQuizTheme(darkTheme = when (theme) {
                ThemeMode.Light -> false
                ThemeMode.Dark -> true
                ThemeMode.System -> isSystemInDarkTheme()
            }) {
                AppRoot()
            }
        }
    }
}
