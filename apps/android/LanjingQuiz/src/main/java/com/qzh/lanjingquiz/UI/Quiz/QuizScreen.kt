package com.qzh.lanjingquiz.UI.Quiz

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.App.ThemeMode
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSOrange
import com.qzh.lanjingquiz.UI.DSRed
import com.qzh.lanjingquiz.UI.HomeTab

/**
 * 考试答题页(iOS QuizView 移植):顶部栏(✕/卷名/计时/主题/放弃) + 进度条 + "第 x / N 题" +
 * HorizontalPager 逐题页(所有翻页经 vm.goTo 单一路径)+ 底部统计条 + 答题卡 overlay + 交卷/放弃两段确认。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun QuizScreen(
    exam: ExamDto,
    appState: AppState,
    vm: QuizViewModel = hiltViewModel(),
) {
    val questions by vm.questions.collectAsState()
    val states by vm.states.collectAsState()
    val page by vm.page.collectAsState()
    val timer by vm.timer.collectAsState()
    val timerMode by vm.timerMode.collectAsState()
    val isLoading by vm.isLoading.collectAsState()
    val loadPhase by vm.loadPhase.collectAsState()
    val errorMessage by vm.errorMessage.collectAsState()
    val showAnswerCard by vm.showAnswerCard.collectAsState()
    val showSubmitConfirm by vm.showSubmitConfirm.collectAsState()
    val showAbandonConfirm by vm.showAbandonConfirm.collectAsState()
    val theme by appState.theme.collectAsState()

    // 进入即加载(同一 exam 幂等);离开时重置使下次重新走完整流程
    LaunchedEffect(Unit) { vm.start(exam) }
    DisposableEffect(Unit) { onDispose { vm.reset() } }

    val pagerState = rememberPagerState(pageCount = { states.size })
    // VM 页号 → Pager(答题卡/自动下一题等程序化跳转)
    LaunchedEffect(page) { if (pagerState.currentPage != page) pagerState.scrollToPage(page) }
    // 手势滑动 → VM(单一路径 goTo,计时重启一次)
    LaunchedEffect(pagerState.currentPage) { vm.goTo(pagerState.currentPage) }

    val backToList: () -> Unit = {
        vm.cancel()
        appState.selectedTab.value = HomeTab.Exams
        appState.navigateTo(Route.Home)
    }

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        when {
            isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(color = DSAccent)
                    loadPhase?.let { Text(it, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF8E8E93)) }
                }
            }
            errorMessage != null && questions.isEmpty() -> ErrorState(
                message = errorMessage!!,
                onRetry = vm::retry,
                onBack = backToList,
            )
            questions.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("没有题目", color = Color(0xFF8E8E93))
            }
            else -> {
                QuizHeader(
                    examName = exam.name,
                    timer = timer,
                    timerMode = timerMode,
                    theme = theme,
                    onClose = backToList,
                    onToggleTheme = appState::toggleTheme,
                    onAbandon = vm::abandon,
                )
                QuizProgressBar(
                    progress = (page + 1).toFloat() / states.size,
                    modifier = Modifier.padding(top = 8.dp),
                )
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("第 ${page + 1} / ${states.size} 题", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
                    Spacer(Modifier.weight(1f))
                    states.getOrNull(page)?.section?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFF8E8E93))
                    }
                }
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.weight(1f),
                ) { index ->
                    QuestionScreen(vm = vm, index = index, dark = theme == ThemeMode.Dark)
                }
                StatsBar(vm = vm, onAnswerCard = vm::openAnswerCard, onSubmit = vm::submit)
            }
        }
    }

    if (showAnswerCard) {
        AnswerCard(vm = vm, onClose = vm::closeAnswerCard)
    }

    if (showSubmitConfirm) {
        AlertDialog(
            onDismissRequest = { vm.showSubmitConfirm.value = false },
            title = { Text("确定提交试卷吗？") },
            confirmButton = {
                Button(
                    onClick = {
                        vm.showSubmitConfirm.value = false
                        vm.submitConfirmed()
                    },
                    modifier = Modifier.testTag("confirm-submit"),
                    colors = ButtonDefaults.buttonColors(containerColor = DSRed),
                ) { Text("提交", color = Color.White) }
            },
            dismissButton = {
                TextButton(onClick = { vm.showSubmitConfirm.value = false }) { Text("取消") }
            },
        )
    }

    if (showAbandonConfirm) {
        AlertDialog(
            onDismissRequest = { vm.showAbandonConfirm.value = false },
            title = { Text("确定放弃「${exam.name}」吗？放弃后本次作答将直接交卷。") },
            confirmButton = {
                Button(
                    onClick = {
                        vm.showAbandonConfirm.value = false
                        vm.abandonConfirmed()
                    },
                    modifier = Modifier.testTag("confirm-abandon"),
                    colors = ButtonDefaults.buttonColors(containerColor = DSRed),
                ) { Text("确认放弃", color = Color.White) }
            },
            dismissButton = {
                TextButton(onClick = { vm.showAbandonConfirm.value = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun QuizHeader(
    examName: String,
    timer: String,
    timerMode: QuizViewModel.TimerMode,
    theme: ThemeMode,
    onClose: () -> Unit,
    onToggleTheme: () -> Unit,
    onAbandon: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("✕", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Color(0xFF8E8E93),
            modifier = Modifier
                .testTag("quiz-close")
                .clickable(onClick = onClose))
        Text(
            examName,
            fontSize = 15.sp,
            fontWeight = FontWeight.Black,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        QuestionTimerPill(timer = timer, mode = timerMode)
        Text(if (theme == ThemeMode.Dark) "☀️" else "🌙", fontSize = 16.sp,
            modifier = Modifier
                .testTag("theme-toggle")
                .clickable(onClick = onToggleTheme))
        Text("放弃", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = DSRed,
            modifier = Modifier
                .testTag("quiz-abandon")
                .clickable(onClick = onAbandon)
                .padding(4.dp))
    }
}

/** 每问 60s 倒计时胶囊:active 橙 / paused 灰 / expired 红(iOS QuestionTimerView)。 */
@Composable
private fun QuestionTimerPill(timer: String, mode: QuizViewModel.TimerMode) {
    val fg = when (mode) {
        QuizViewModel.TimerMode.Active -> DSOrange
        QuizViewModel.TimerMode.Paused -> Color(0xFF8E8E93)
        QuizViewModel.TimerMode.Expired -> DSRed
    }
    val bg = when (mode) {
        QuizViewModel.TimerMode.Active -> DSOrange.copy(alpha = 0.15f)
        QuizViewModel.TimerMode.Paused -> Color(0xFFE5E5EA)
        QuizViewModel.TimerMode.Expired -> DSRed.copy(alpha = 0.15f)
    }
    Surface(shape = CircleShape, color = bg) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("⏱", fontSize = 13.sp)
            Text(timer, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = fg)
        }
    }
}

@Composable
private fun ErrorState(message: String, onRetry: () -> Unit, onBack: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(message, fontSize = 15.sp, color = Color(0xFF3C3C3C))
        Button(
            onClick = onRetry,
            modifier = Modifier.padding(top = 16.dp).width(160.dp),
            shape = MaterialTheme.shapes.extraLarge,
            colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
        ) { Text("重试", color = Color.White) }
        TextButton(onClick = onBack) { Text("返回", color = Color(0xFF8E8E93)) }
    }
}
