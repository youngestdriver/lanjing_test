package com.qzh.lanjingquiz.UI.Practice

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.ThemeMode
import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.PracticeAnswer
import com.qzh.lanjingquiz.Data.PracticeSession
import com.qzh.lanjingquiz.Domain.OptionMarker
import com.qzh.lanjingquiz.Network.TestConfig
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSBlue
import com.qzh.lanjingquiz.UI.DSOrange
import com.qzh.lanjingquiz.UI.DSRed
import com.qzh.lanjingquiz.UI.Quiz.ExplainBanner
import com.qzh.lanjingquiz.UI.Shared.RichHtmlBody

/**
 * 刷题页(iOS PracticeQuizView 移植):VStack(spacing:0){header(第 x/y 题 + 多选/无答案
 * 徽标);恢复横幅?;HorizontalPager 分页;PracticeStatsBar},答题卡 overlay。
 * 作答判定:单选即判 / 多选提交判 / 无答案 reveal 不计对错;reveal 后记进度注册表。
 * 系统返回仅退出练习页(不清会话文件);完成(下一题越过末尾)→ 清文件,summary 保留内存。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PracticeQuizScreen(
    appState: AppState,
    bankVm: PracticeBankViewModel,
    vm: PracticeQuizViewModel,
    category: String,
    subCategory: String,
    onBack: () -> Unit,
) {
    val session by vm.session.collectAsState()
    val page by vm.page.collectAsState()
    val showAnswerCard by vm.showAnswerCard.collectAsState()
    val resumed by vm.resumedFromDisk.collectAsState()
    val theme by appState.theme.collectAsState()
    val dark = theme == ThemeMode.Dark
    val baseUrl = TestConfig.effectiveBaseUrl()

    // 建/恢复会话(iOS .task resumeOrStart);进入即执行,系统返回再进入续跑
    var started by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val result = bankVm.startPractice(category, subCategory)
        vm.start(result.session, resumed = result.resumed)
        started = true
    }
    // 系统返回仅退出练习页(不清会话;仅 endSession/完成清文件)
    BackHandler(onBack = onBack)

    val current = session
    when {
        !started || current == null -> Loading()
        current.questions.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("没有题目", color = Color(0xFF8E8E93))
        }
        current.isFinished -> SummaryCard(
            session = current,
            onDone = {
                vm.endSession()
                onBack()
            },
        )
        else -> {
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                HeaderRow(session = current, index = current.index)
                if (resumed && !current.isFinished) {
                    ResumeBanner(onDismiss = vm::consumeResumeNotice)
                }
                QuizPager(vm = vm, session = current, page = page, dark = dark, baseUrl = baseUrl)
                PracticeStatsBar(
                    vm = vm,
                    onAnswerCard = vm::openAnswerCard,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }

    if (showAnswerCard) {
        PracticeAnswerCard(vm = vm, onClose = vm::closeAnswerCard)
    }
}

@Composable
private fun Loading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(color = DSAccent)
            Text("正在加载题目…", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF8E8E93))
        }
    }
}

/** 第 x/y 题 + 多选(蓝)/无答案(橙)徽标。 */
@Composable
private fun HeaderRow(session: PracticeSession, index: Int) {
    val question = session.questions.getOrNull(index) ?: return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(shape = CircleShape, color = Color(0xFFE5E5EA)) {
            Text(
                "第 ${index + 1}/${session.questions.size} 题",
                fontSize = 13.sp,
                fontWeight = FontWeight.Black,
                color = Color(0xFF3C3C3C),
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
        if (question.answer is AnswerShape.Multi) {
            Surface(shape = CircleShape, color = DSBlue.copy(alpha = 0.12f)) {
                Text(
                    "多选",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Black,
                    color = DSBlue,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
        if (question.answer == null || question.answer is AnswerShape.None) {
            Surface(shape = CircleShape, color = DSOrange.copy(alpha = 0.12f)) {
                Text(
                    "无答案",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Black,
                    color = DSOrange,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
        Spacer(Modifier.weight(1f))
    }
}

/** 一次性恢复横幅:已恢复上次练习进度 + 知道了。 */
@Composable
private fun ResumeBanner(onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .background(DSBlue.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("已恢复上次练习进度", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = DSBlue)
        Spacer(Modifier.weight(1f))
        Text(
            "知道了",
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = DSBlue,
            modifier = Modifier
                .clickable(onClick = onDismiss)
                .padding(4.dp),
        )
    }
}

/** 分页容器:所有翻页(手势/答题卡跳转)经 vm.goTo 单一路径;索引持久化。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun androidx.compose.foundation.layout.ColumnScope.QuizPager(
    vm: PracticeQuizViewModel,
    session: PracticeSession,
    page: Int,
    dark: Boolean,
    baseUrl: String,
) {
    val pagerState = rememberPagerState(pageCount = { session.questions.size })
    LaunchedEffect(page) { if (pagerState.currentPage != page) pagerState.scrollToPage(page) }
    LaunchedEffect(pagerState.currentPage) { vm.goTo(pagerState.currentPage) }

    HorizontalPager(
        state = pagerState,
        modifier = Modifier.weight(1f),
    ) { index ->
        QuestionPage(
            session = session,
            index = index,
            onTap = vm::tapOption,
            onConfirm = vm::confirmSelection,
            onNext = vm::nextQuestion,
            dark = dark,
            baseUrl = baseUrl,
        )
    }
}

/** 单页 = 可滚动题目页:材料(stem)+ 题干 + 选项行 + 作答后解析横幅 + 下一题/完成。 */
@Composable
private fun QuestionPage(
    session: PracticeSession,
    index: Int,
    onTap: (String) -> Unit,
    onConfirm: () -> Unit,
    onNext: () -> Unit,
    dark: Boolean,
    baseUrl: String,
) {
    val question = session.questions.getOrNull(index) ?: return
    val answer = session.answers.getOrNull(index) ?: PracticeAnswer()
    val isLast = index + 1 >= session.questions.size
    val gradable = question.answer != null && question.answer !is AnswerShape.None

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        question.stem?.takeIf { it.isNotBlank() }?.let { stem ->
            RichHtmlBody(
                html = stem,
                fontSizeSp = 15,
                dark = dark,
                allowTextSelection = false,
                baseUrl = baseUrl,
            )
            Surface(color = Color(0xFFE5E5EA), modifier = Modifier.fillMaxWidth().height(1.dp)) {}
        }

        RichHtmlBody(
            html = question.question,
            fontSizeSp = 17,
            dark = dark,
            allowTextSelection = false,
            baseUrl = baseUrl,
        )

        PracticeOptions(
            question = question,
            answer = answer,
            onTap = onTap,
            onConfirm = onConfirm,
            dark = dark,
            baseUrl = baseUrl,
        )

        if (answer.revealed) {
            ExplainBanner(
                correct = answer.correct == true,
                hasAnswer = gradable,
                answerLabel = question.answer?.letters?.joinToString("、") ?: "?",
                analysis = question.analysis.orEmpty(),
                dark = dark,
                baseUrl = baseUrl,
            )
            Button(
                onClick = onNext,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("practice-next"),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
            ) {
                Text(
                    if (isLast) "完成" else "下一题",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                )
            }
        }
    }
}

/** 选项行 + 多选提交按钮。 */
@Composable
private fun PracticeOptions(
    question: BankQuestion,
    answer: PracticeAnswer,
    onTap: (String) -> Unit,
    onConfirm: () -> Unit,
    dark: Boolean,
    baseUrl: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        listOf("A", "B", "C", "D").forEachIndexed { i, letter ->
            PracticeOptionRow(
                question = question,
                letter = letter,
                optionText = question.options.getOrNull(i).orEmpty(),
                answer = answer,
                onTap = { onTap(letter) },
                dark = dark,
                baseUrl = baseUrl,
            )
        }
        if (question.answer is AnswerShape.Multi && !answer.revealed && answer.selected.isNotEmpty()) {
            Button(
                onClick = onConfirm,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("practice-multi-submit"),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
            ) {
                Text("提交", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
            }
        }
    }
}

/**
 * 无状态选项行(iOS PracticeOptionRowView 移植):空槽(填空)灰占位不可点;
 * 作答后选中且错标红、正确标绿(多选答错时参考答案仍 ✅);无答案已答 → 灰 key 无判定。
 */
@Composable
private fun PracticeOptionRow(
    question: BankQuestion,
    letter: String,
    optionText: String,
    answer: PracticeAnswer,
    onTap: () -> Unit,
    dark: Boolean,
    baseUrl: String,
) {
    val isEmptySlot = optionText.isBlank()
    val isAnswered = answer.revealed
    val isSelected = answer.selected.contains(letter)
    val gradable = question.answer != null && question.answer !is AnswerShape.None
    val isCorrect = question.answer?.letters?.contains(letter) == true
    // 判定上色仅在作答后(无答案题 correct==null → 无判定,回落选中蓝)
    val mark: OptionMarker? = when {
        !isAnswered || answer.correct == null -> null
        isCorrect -> OptionMarker.Correct
        isSelected -> OptionMarker.Wrong
        else -> null
    }

    val bg = when (mark) {
        OptionMarker.Correct -> DSAccent.copy(alpha = 0.12f)
        OptionMarker.Wrong -> DSRed.copy(alpha = 0.12f)
        null -> if (isSelected) DSBlue.copy(alpha = 0.12f) else Color(0xFFF2F2F2)
    }
    val border = when (mark) {
        OptionMarker.Correct -> DSAccent
        OptionMarker.Wrong -> DSRed
        null -> if (isSelected) DSBlue else Color(0xFFD1D1D6)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg, RoundedCornerShape(12.dp))
            .border(2.dp, border, RoundedCornerShape(12.dp))
            .clickable(enabled = !isAnswered && !isEmptySlot, onClick = onTap)
            .testTag("practice-option-$letter")
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Keycap(mark = mark, answered = isAnswered, letter = letter, isSelected = isSelected)
        if (isEmptySlot) {
            Text(
                "（填空）",
                fontSize = 15.sp,
                color = Color(0xFF8E8E93),
                modifier = Modifier.padding(top = 5.dp),
            )
        } else {
            RichHtmlBody(
                html = optionText,
                fontSizeSp = 16,
                dark = dark,
                allowTextSelection = false,
                baseUrl = baseUrl,
            )
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun Keycap(mark: OptionMarker?, answered: Boolean, letter: String, isSelected: Boolean) {
    val fill = when (mark) {
        OptionMarker.Correct -> DSAccent
        OptionMarker.Wrong -> DSRed
        null -> if (answered) Color(0xFFE5E5EA) else if (isSelected) DSBlue else Color(0xFFF2F2F2)
    }
    val border = when (mark) {
        OptionMarker.Correct, OptionMarker.Wrong -> Color.Transparent
        null -> Color(0xFFD1D1D6)
    }
    val textColor = when (mark) {
        OptionMarker.Correct, OptionMarker.Wrong -> Color.White
        null -> if (answered) Color(0xFF8E8E93) else if (isSelected) DSBlue else Color(0xFF3C3C3C)
    }
    Box(
        modifier = Modifier
            .size(30.dp)
            .background(fill, RoundedCornerShape(8.dp))
            .border(2.dp, border, RoundedCornerShape(8.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (answered && mark != null) (if (mark == OptionMarker.Correct) "✓" else "✗") else letter,
            fontSize = 13.sp,
            fontWeight = FontWeight.Black,
            color = textColor,
        )
    }
}

/** 完成页 summaryCard:练习完成 / 答对 X 题 / 答错 X 题 / 共 N 题 / 返回题型列表。 */
@Composable
private fun SummaryCard(session: PracticeSession, onDone: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(if (session.wrongCount == 0) "🎉" else "🏁", fontSize = 44.sp)
        Text("练习完成", fontSize = 20.sp, fontWeight = FontWeight.Black, color = Color(0xFF3C3C3C))
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 16.dp),
        ) {
            Text("答对 ${session.rightCount} 题", fontSize = 15.sp, color = Color(0xFF3C3C3C))
            Text("答错 ${session.wrongCount} 题", fontSize = 15.sp, color = Color(0xFF3C3C3C))
            Text("共 ${session.questions.size} 题", fontSize = 15.sp, color = Color(0xFF8E8E93))
        }
        Button(
            onClick = onDone,
            modifier = Modifier
                .padding(top = 24.dp)
                .testTag("practice-finish-back"),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
        ) {
            Text("返回题型列表", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.White)
        }
    }
}
