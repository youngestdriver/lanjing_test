package com.qzh.lanjingquiz.UI.ExamList

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSBlue
import com.qzh.lanjingquiz.UI.DSPink
import com.qzh.lanjingquiz.UI.DSRed

/**
 * 考试列表(iOS ExamListView/ExamCardView 移植):按 style 分组、"机考题库"排前、
 * 新试卷(蓝)/继续考试(绿)徽标、练习模式徽标、不限时/N分钟;点击进入,长按放弃(两段确认)。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ExamListScreen(vm: ExamListViewModel = hiltViewModel()) {
    val phase by vm.phase.collectAsState()
    val groups by vm.groups.collectAsState()
    var abandonTarget by remember { mutableStateOf<ExamDto?>(null) }

    LaunchedEffect(Unit) { vm.refresh() }

    Box(Modifier.fillMaxSize().statusBarsPadding()) {
        when (phase) {
            is ExamListViewModel.Phase.Loading -> if (groups.isEmpty()) {
                CircularProgressIndicator(Modifier.align(Alignment.Center), color = DSAccent)
            }
            is ExamListViewModel.Phase.Failed -> if (groups.isEmpty()) {
                Column(
                    modifier = Modifier.align(Alignment.Center).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text((phase as ExamListViewModel.Phase.Failed).msg, fontSize = 15.sp, color = Color(0xFF3C3C3C))
                    Button(
                        onClick = vm::refresh,
                        modifier = Modifier.width(160.dp),
                        shape = MaterialTheme.shapes.extraLarge,
                        colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
                    ) { Text("重试", color = Color.White) }
                }
            }
            is ExamListViewModel.Phase.Empty -> Text("没有考试", color = Color(0xFF8E8E93), modifier = Modifier.align(Alignment.Center))
            else -> Unit
        }

        if (groups.isNotEmpty()) {
            LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp)) {
                groups.forEach { group ->
                    item(key = "header-${group.styleName}") {
                        Text(
                            group.styleName,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color(0xFF8E8E93),
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                        )
                    }
                    items(group.exams.size, key = { i -> "exam-${group.exams[i].id}" }) { i ->
                        val exam = group.exams[i]
                        ExamCard(
                            exam = exam,
                            onClick = { vm.enter(exam) },
                            onLongClick = { abandonTarget = exam },
                        )
                    }
                }
            }
        }
    }

    abandonTarget?.let { exam ->
        AlertDialog(
            onDismissRequest = { abandonTarget = null },
            title = { Text("确定放弃「${exam.name}」吗？放弃后本次作答将直接交卷。") },
            confirmButton = {
                Button(
                    onClick = {
                        abandonTarget = null
                        vm.abandon(exam)
                    },
                    modifier = Modifier.testTag("confirm-abandon-list"),
                    colors = ButtonDefaults.buttonColors(containerColor = DSRed),
                ) { Text("确认放弃", color = Color.White) }
            },
            dismissButton = {
                TextButton(onClick = { abandonTarget = null }) { Text("取消") }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ExamCard(exam: ExamDto, onClick: () -> Unit, onLongClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .testTag("exam-card-${exam.id}")
            .background(Color(0xFFF7F7F8), RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .background(DSAccent, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text("📄", fontSize = 22.sp)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                exam.name,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                color = Color(0xFF3C3C3C),
                maxLines = 2,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Badge(if (exam.wfs == 1) "新试卷" else "继续考试",
                    color = if (exam.wfs == 1) DSBlue else DSAccent)
                Badge(modeLabel(exam), color = DSPink)
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(timeLabel(exam), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF8E8E93))
            Text("›", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Color(0xFFC7C7CC))
        }
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Surface(shape = CircleShape, color = color.copy(alpha = 0.12f)) {
        Text(
            text,
            fontSize = 11.sp,
            fontWeight = FontWeight.Black,
            color = color,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
        )
    }
}

/** iOS Exam.modeLabel:practiceMode 0 → 模拟考试,1 → MOCK,2 → 练习。 */
internal fun modeLabel(exam: ExamDto): String = when (exam.practiceMode) {
    0 -> "模拟考试"
    1 -> "MOCK"
    2 -> "练习"
    else -> "?"
}

/** iOS Exam.timeLabel:totalTime == 0 → 不限时。 */
internal fun timeLabel(exam: ExamDto): String =
    if ((exam.examTime ?: 0) == 0) "不限时" else "${exam.examTime}分钟"
