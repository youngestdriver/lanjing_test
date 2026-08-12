package com.qzh.lanjingquiz.UI.Practice

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSRed

/**
 * 练习答题页底部统计栏(iOS PracticeStatsBarView 移植):答对绿✓/答错红✗/未答灰○
 * + 答题卡胶囊,**无交卷**(练习永不交卷)。未答 = questions.size - answeredCount
 * (显式括号防优先级错误;无答案题已答计入 answeredCount)。
 */
@Composable
fun PracticeStatsBar(
    vm: PracticeQuizViewModel,
    onAnswerCard: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val session by vm.session.collectAsState()

    val right = session?.rightCount ?: 0
    val wrong = session?.wrongCount ?: 0
    val unanswered = (session?.questions?.size ?: 0) - (session?.answeredCount ?: 0)

    Surface(color = Color(0xFFF2F2F2), modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatItem("$right", "✓", DSAccent)
                StatItem("$wrong", "✗", DSRed)
                StatItem("$unanswered", "○", Color(0xFF8E8E93))
            }
            Spacer(Modifier.weight(1f))
            Surface(
                shape = CircleShape,
                color = Color(0xFFE5E5EA),
                modifier = Modifier.testTag("practice-answer-card-btn"),
            ) {
                Text(
                    "答题卡",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFF3C3C3C),
                    modifier = Modifier
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                        .clickable(onClick = onAnswerCard),
                )
            }
        }
    }
}

@Composable
private fun StatItem(text: String, glyph: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(glyph, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = color)
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = color)
    }
}
