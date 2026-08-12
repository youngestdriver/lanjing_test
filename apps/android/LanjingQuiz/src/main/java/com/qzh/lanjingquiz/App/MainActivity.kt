package com.qzh.lanjingquiz.App

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.qzh.lanjingquiz.UI.AppRoot
import com.qzh.lanjingquiz.UI.LanjingQuizTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            LanjingQuizTheme { AppRoot() }
        }
    }
}
