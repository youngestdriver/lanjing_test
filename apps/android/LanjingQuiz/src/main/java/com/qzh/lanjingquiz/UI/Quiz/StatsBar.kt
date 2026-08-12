package com.qzh.lanjingquiz.UI.Quiz

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
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
import com.qzh.lanjingquiz.Domain.QuizLogic
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSRed

/**
 * 底部统计条(iOS StatsBarView 移植):答对/答错/未答统计 + 答题卡入口 + 交卷(红)。
 * 进度条(高 16dp)附于上方。
 */
@Composable
fun StatsBar(
    vm: QuizViewModel,
    onAnswerCard: () -> Unit,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val states by vm.states.collectAsState()
    val isSubmitting by vm.isSubmitting.collectAsState()

    val right = states.count { it.state == QuizLogic.STATE_RIGHT }
    val error = states.count { it.state == QuizLogic.STATE_ERROR }
    val unanswered = states.count { it.state == QuizLogic.STATE_UNANSWERED }

    Surface(color = Color(0xFFF2F2F2), modifier = modifier) {
        Column {
            QuizProgressBar(
                progress = if (states.isEmpty()) 0f
                    else (vm.page.collectAsState().value + 1).coerceAtMost(states.size).toFloat() / states.size,
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    StatItem("$right", "✓", DSAccent)
                    StatItem("$error", "✗", DSRed)
                    StatItem("$unanswered", "○", Color(0xFF8E8E93))
                }
                Spacer(Modifier.weight(1f))
                Surface(
                    shape = CircleShape,
                    color = Color(0xFFE5E5EA),
                    modifier = Modifier.testTag("answer-card-btn"),
                ) {
                    Text(
                        "答题卡",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF3C3C3C),
                        modifier = Modifier
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                            .testTag("answer-card-btn-text"),
                    )
                }
                Spacer(Modifier.width(12.dp))
                if (isSubmitting) {
                    CircularProgressIndicator(modifier = Modifier.size(28.dp), color = DSRed, strokeWidth = 2.5.dp)
                } else {
                    Button(
                        onClick = onSubmit,
                        modifier = Modifier
                            .width(92.dp)
                            .height(44.dp)
                            .testTag("submit-exam"),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = DSRed),
                    ) {
                        Text("交卷", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
                    }
                }
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

/** 16pt 绿色进度条(iOS ProgressBarView 移植)。 */
@Composable
fun QuizProgressBar(progress: Float, modifier: Modifier = Modifier) {
    Surface(
        color = Color(0xFFE5E5EA),
        shape = CircleShape,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(16.dp),
    ) {
        Surface(
            color = DSAccent,
            shape = CircleShape,
            modifier = Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)),
        ) {}
    }
}

