package com.qzh.lanjingquiz.UI

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** T5 替换:练习占位屏。 */
@Composable
fun PracticeBankScreenPlaceholder(padding: PaddingValues) = PlaceholderScreen("练习", padding)

/** T6 替换:我的占位屏。 */
@Composable
fun ProfileScreenPlaceholder(padding: PaddingValues) = PlaceholderScreen("我的", padding)

@Composable
private fun PlaceholderScreen(title: String, padding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        Text(title, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
