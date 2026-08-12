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
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.Network.ExamResult

/** T3 替换:考试列表占位屏。 */
@Composable
fun ExamListScreenPlaceholder(padding: PaddingValues) = PlaceholderScreen("考试列表", padding)

/** T5 替换:练习占位屏。 */
@Composable
fun PracticeBankScreenPlaceholder(padding: PaddingValues) = PlaceholderScreen("练习", padding)

/** T6 替换:我的占位屏。 */
@Composable
fun ProfileScreenPlaceholder(padding: PaddingValues) = PlaceholderScreen("我的", padding)

/** T3 实现:考试答题屏(骨架,考试模块落地后替换)。 */
@Composable
fun QuizScreen(exam: ExamDto) {
    PlaceholderScreen("考试进行中（待实现）", PaddingValues(0.dp))
}

/** T3 实现:结果屏(骨架,考试模块落地后替换)。 */
@Composable
fun ResultScreen(result: ExamResult, examName: String) {
    PlaceholderScreen("考试结果（待实现）", PaddingValues(0.dp))
}

@Composable
private fun PlaceholderScreen(title: String, padding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        Text(title, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
