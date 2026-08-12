package com.qzh.lanjingquiz.UI

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

// DS 调色板(spec §3.5):accent 0x58cc02, accentHover 0x61e002, accentActive 0x58a700,
// orange 0xff9600, blue 0x1cb0f6, pink 0xce82ff, red 0xff4b4b, yellow 0xffc800, gray 0xafafaf
val DSAccent = Color(0xFF58CC02)
val DSAccentHover = Color(0xFF61E002)
val DSAccentActive = Color(0xFF58A700)
val DSOrange = Color(0xFFFF9600)
val DSBlue = Color(0xFF1CB0F6)
val DSPink = Color(0xFFCE82FF)
val DSRed = Color(0xFFFF4B4B)
val DSYellow = Color(0xFFFFC800)
val DSGray = Color(0xFFAFAFAF)

val DSRadiusSM = 12.dp
val DSRadiusMD = 16.dp
val DSRadiusLG = 20.dp
val DSRadiusFull = 9999.dp

private val LightColors = lightColorScheme(
    primary = DSAccent, secondary = DSBlue, error = DSRed, tertiary = DSPink,
)
private val DarkColors = darkColorScheme(
    primary = DSAccent, secondary = DSBlue, error = DSRed, tertiary = DSPink,
)

@Composable
fun LanjingQuizTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
