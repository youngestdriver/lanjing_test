package com.qzh.lanjingquiz.UI.Quiz

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.qzh.lanjingquiz.Domain.OptionMarker
import com.qzh.lanjingquiz.Domain.QuizLogic
import com.qzh.lanjingquiz.Network.QuestionDto
import com.qzh.lanjingquiz.Network.TestConfig
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSBlue
import com.qzh.lanjingquiz.UI.DSOrange
import com.qzh.lanjingquiz.UI.DSRed
import com.qzh.lanjingquiz.UI.Shared.RichHtmlBody

/**
 * 单题页(iOS QuestionView.regularLayout 移植):题号徽标 + 多选徽标 + 🔖;
 * 组合题材料(stem) + 题干 WebView;选项行(判定上色);作答后解析横幅。
 */
@Composable
fun QuestionScreen(
    vm: QuizViewModel,
    index: Int,
    dark: Boolean,
) {
    val questions by vm.questions.collectAsState()
    val states by vm.states.collectAsState()
    val answers by vm.answers.collectAsState()
    val pendingMulti by vm.pendingMulti.collectAsState()
    val baseUrl = TestConfig.effectiveBaseUrl()

    val question = questions.getOrNull(index) ?: return
    val state = states.getOrNull(index) ?: return
    val answered = state.state != QuizLogic.STATE_UNANSWERED
    val selected = answers[question.id] ?: emptyList()
    val isMulti = QuizLogic.isMulti(question)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        HeaderRow(
            num = state.num,
            isMulti = isMulti,
            marked = state.marked,
            onToggleMark = vm::toggleMark,
        )

        question.parentInfo?.takeIf { it.isNotBlank() }?.let { stem ->
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

        Options(
            vm = vm,
            question = question,
            num = state.num,
            answered = answered,
            selected = selected,
            pending = pendingMulti,
            questionState = state.state,
            dark = dark,
            baseUrl = baseUrl,
        )

        if (answered) {
            ExplainBanner(
                correct = state.state == QuizLogic.STATE_RIGHT,
                hasAnswer = QuizLogic.isGradable(question),
                answerLabel = answerLabel(question),
                analysis = question.analysis,
                dark = dark,
                baseUrl = baseUrl,
            )
        }
    }
}

@Composable
private fun HeaderRow(num: String, isMulti: Boolean, marked: Boolean, onToggleMark: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Surface(shape = CircleShape, color = Color(0xFFE5E5EA)) {
            Text(
                "第 $num 题",
                fontSize = 13.sp,
                fontWeight = FontWeight.Black,
                color = Color(0xFF3C3C3C),
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
        if (isMulti) {
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
        Spacer(Modifier.weight(1f))
        Text(
            "🔖",
            fontSize = 16.sp,
            modifier = Modifier
                .testTag("mark-btn")
                .clickable(onClick = onToggleMark)
                .alpha(if (marked) 1f else 0.35f)
                .padding(6.dp),
        )
    }
}

@Composable
private fun Options(
    vm: QuizViewModel,
    question: QuestionDto,
    num: String,
    answered: Boolean,
    selected: List<String>,
    pending: Set<String>,
    questionState: String,
    dark: Boolean,
    baseUrl: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        listOf("A", "B", "C", "D").forEachIndexed { i, letter ->
            val optionText = question.optionTexts().getOrNull(i).orEmpty()
            if (optionText.isEmpty()) return@forEachIndexed
            OptionRow(
                vm = vm,
                question = question,
                num = num,
                letter = letter,
                optionText = optionText,
                answered = answered,
                isSelected = letter in selected || letter in pending,
                questionState = questionState,
                dark = dark,
                baseUrl = baseUrl,
            )
        }
        if (QuizLogic.isMulti(question) && !answered && pending.isNotEmpty()) {
            Button(
                onClick = vm::confirmSelection,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("multi-submit"),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
            ) {
                Text("提交", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
            }
        }
    }
}

@Composable
private fun OptionRow(
    vm: QuizViewModel,
    question: QuestionDto,
    num: String,
    letter: String,
    optionText: String,
    answered: Boolean,
    isSelected: Boolean,
    questionState: String,
    dark: Boolean,
    baseUrl: String,
) {
    val gradable = QuizLogic.isGradable(question)
    val isCorrect = QuizLogic.correctLetters(question).contains(letter)
    val mark = QuizLogic.optionResult(
        isAnswered = answered,
        isSelected = isSelected,
        isCorrect = if (gradable) isCorrect else null,
        isMulti = QuizLogic.isMulti(question),
        questionState = questionState,
    )

    val bg = when (mark) {
        OptionMarker.Correct -> DSAccent.copy(alpha = 0.12f)
        OptionMarker.Wrong -> DSRed.copy(alpha = 0.12f)
        null -> if (isSelected && !answered) DSBlue.copy(alpha = 0.12f) else Color(0xFFF2F2F2)
    }
    val border = when (mark) {
        OptionMarker.Correct -> DSAccent
        OptionMarker.Wrong -> DSRed
        null -> if (isSelected && !answered) DSBlue else Color(0xFFD1D1D6)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg, RoundedCornerShape(12.dp))
            .border(2.dp, border, RoundedCornerShape(12.dp))
            .clickable(enabled = !answered) { vm.tapOption(letter) }
            .testTag("option-$num-$letter")
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Keycap(mark = mark, answered = answered, letter = letter, isSelected = isSelected)
        RichHtmlBody(
            html = optionText,
            fontSizeSp = 16,
            dark = dark,
            allowTextSelection = false,
            baseUrl = baseUrl,
        )
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

/** 解析横幅(iOS ExplainBannerView 移植):结论 + 正确答案 + 解析。 */
@Composable
fun ExplainBanner(
    correct: Boolean,
    hasAnswer: Boolean,
    answerLabel: String,
    analysis: String,
    dark: Boolean,
    baseUrl: String,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (correct) DSAccent.copy(alpha = 0.12f) else DSRed.copy(alpha = 0.12f), RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            if (correct) "棒极了！回答正确！" else "加油！再接再厉！",
            fontSize = 15.sp,
            fontWeight = FontWeight.Black,
            color = Color(0xFF3C3C3C),
        )
        if (!correct && hasAnswer) {
            Text("正确答案：$answerLabel", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = DSAccent)
        } else if (!hasAnswer) {
            Text("本题暂无标准答案", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = DSOrange)
        }
        if (analysis.isNotBlank()) {
            RichHtmlBody(html = analysis, fontSizeSp = 14, dark = dark, allowTextSelection = false, baseUrl = baseUrl)
        }
    }
}

/** 正确答案文案:正确字母 "A、C";无答案题回退 test_ans_right,再回退 "?"。 */
private fun answerLabel(question: QuestionDto): String {
    val correct = QuizLogic.correctLetters(question)
    if (correct.isNotEmpty()) return correct.joinToString("、")
    return question.testAnsRight.ifBlank { "?" }
}
