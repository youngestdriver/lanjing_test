package com.qzh.lanjingquiz.UI.Practice

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.qzh.lanjingquiz.Data.PracticeAnswer
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSBlue
import com.qzh.lanjingquiz.UI.DSOrange
import com.qzh.lanjingquiz.UI.DSRed

/**
 * 练习答题卡 overlay(iOS PracticeAnswerCardView 移植;overlay 非 sheet):
 * 统计行 + 7 列 dot 网格,**无 section、无交卷**。点 dot → vm.goTo + 关闭;
 * dot 36dp:答对绿/答错红/未答灰、当前 3dp 蓝圈、无答案已答橙边;自动滚动当前题居中。
 */
@Composable
fun PracticeAnswerCard(
    vm: PracticeQuizViewModel,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val session by vm.session.collectAsState()
    val page by vm.page.collectAsState()
    val current = session ?: return
    val gridState = rememberLazyGridState()

    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag("practice-answer-card-overlay"),
    ) {
        // 半透明遮罩(点击关闭)
        Box(
            Modifier
                .fillMaxSize()
                .background(Color(0x66000000))
                .clickable(onClick = onClose),
        )
        Surface(
            color = Color(0xFFFFFFFF),
            shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(420.dp)
                .testTag("practice-answer-card-panel"),
        ) {
            Column {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("答题卡", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onClose, modifier = Modifier.testTag("practice-answer-card-close")) {
                        Text("完成", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = DSBlue)
                    }
                }
                // 答对/答错/未答统计(由 answers 派生,永不漂移)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color(0xFFF2F2F2))
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CardStat("${current.rightCount}", "✓", DSAccent)
                    CardStat("${current.wrongCount}", "✗", DSRed)
                    CardStat("${current.questions.size - current.answeredCount}", "○", Color(0xFF8E8E93))
                }
                // 自动滚动当前题居中
                LaunchedEffect(page) {
                    if (page in current.questions.indices) {
                        gridState.animateScrollToItem(page)
                    }
                }
                LazyVerticalGrid(
                    columns = GridCells.Fixed(7),
                    state = gridState,
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag("practice-answer-card-grid"),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    itemsIndexed(current.questions, key = { index, _ -> index }) { index, _ ->
                        CardDot(
                            answer = current.answers.getOrNull(index) ?: PracticeAnswer(),
                            number = index + 1,
                            isCurrent = index == page,
                            onClick = {
                                vm.goTo(index)
                                onClose()
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CardStat(text: String, glyph: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(glyph, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = color)
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = color)
    }
}

/** 答对绿/答错红/未答灰;当前 3dp 蓝圈优先;无答案已答橙边。 */
@Composable
private fun CardDot(answer: PracticeAnswer, number: Int, isCurrent: Boolean, onClick: () -> Unit) {
    val fill = when (answer.correct) {
        true -> DSAccent
        false -> DSRed
        null -> Color(0xFFE5E5EA)
    }
    val border = when {
        isCurrent -> DSBlue
        answer.correct == true -> DSAccent
        answer.correct == false -> DSRed
        answer.revealed -> DSOrange
        else -> Color(0xFFD1D1D6)
    }
    val foreground = when {
        answer.correct != null -> Color.White
        isCurrent -> DSBlue
        else -> Color(0xFF8E8E93)
    }
    Box(modifier = Modifier.size(36.dp), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .background(fill, CircleShape)
                .border(if (isCurrent) 3.dp else 1.dp, border, CircleShape)
                .clickable(onClick = onClick)
                .testTag("practice-dot-$number"),
            contentAlignment = Alignment.Center,
        ) {
            Text(number.toString(), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = foreground)
        }
    }
}
