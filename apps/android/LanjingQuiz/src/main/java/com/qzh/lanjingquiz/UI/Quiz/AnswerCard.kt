package com.qzh.lanjingquiz.UI.Quiz

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
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
import com.qzh.lanjingquiz.Domain.QuizLogic

/**
 * 答题卡 overlay(iOS AnswerCardSheet 移植;保持 overlay 形态而非 sheet):
 * section tabs(含 "全部";单 section 隐藏)+ 7 列弹性 dot 网格;
 * dot 36dp:答对绿/答错红/未答灰/当前 3dp 蓝圈、marked 🔖;自动滚动当前题居中。
 */
@Composable
fun AnswerCard(
    vm: QuizViewModel,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val states by vm.states.collectAsState()
    val sectionTabs by vm.sectionTabs.collectAsState()
    val selectedSection by vm.selectedSection.collectAsState()
    val page by vm.page.collectAsState()

    val visibleIndices = states.indices.filter { index ->
        selectedSection == null || states[index].section == selectedSection
    }
    val gridState = rememberLazyGridState()

    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag("answer-card-overlay"),
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
                .height(480.dp)
                .testTag("answer-card-panel"),
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
                    TextButton(onClick = onClose, modifier = Modifier.testTag("answer-card-close")) {
                        Text("完成", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color(0xFF1CB0F6))
                    }
                }
                if (sectionTabs.size > 1) {
                    SectionTabs(vm = vm, tabs = sectionTabs, selected = selectedSection)
                }
                // 自动滚动当前题居中
                LaunchedEffect(page) {
                    if (page in visibleIndices) {
                        gridState.animateScrollToItem(visibleIndices.indexOf(page))
                    }
                }
                LazyVerticalGrid(
                    columns = GridCells.Fixed(7),
                    state = gridState,
                    modifier = Modifier.fillMaxSize(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    itemsIndexed(visibleIndices, key = { _, idx -> idx }) { _, index ->
                        Dot(
                            state = states[index],
                            isCurrent = index == page,
                            onClick = { vm.goTo(index) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionTabs(vm: QuizViewModel, tabs: List<String?>, selected: String?) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        tabs.forEach { section ->
            val label = section?.let { QuizLogic.sectionTabLabel(it) } ?: "全部"
            val isSelected = selected == section
            Surface(
                shape = CircleShape,
                color = if (isSelected) com.qzh.lanjingquiz.UI.DSAccent else Color(0xFFE5E5EA),
                modifier = Modifier.clickable { vm.jumpToSection(section) },
            ) {
                Text(
                    label,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (isSelected) Color.White else Color(0xFF3C3C3C),
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun Dot(state: QuestionState, isCurrent: Boolean, onClick: () -> Unit) {
    val fill = when (state.state) {
        QuizLogic.STATE_RIGHT -> com.qzh.lanjingquiz.UI.DSAccent
        QuizLogic.STATE_ERROR -> com.qzh.lanjingquiz.UI.DSRed
        else -> Color(0xFFE5E5EA)
    }
    val border = if (isCurrent) com.qzh.lanjingquiz.UI.DSBlue else Color(0xFFD1D1D6)
    val foreground = when {
        state.state != QuizLogic.STATE_UNANSWERED -> Color.White
        isCurrent -> com.qzh.lanjingquiz.UI.DSBlue
        else -> Color(0xFF8E8E93)
    }
    Box(modifier = Modifier.size(36.dp), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .background(fill, CircleShape)
                .border(if (isCurrent) 3.dp else 1.dp, border, CircleShape)
                .clickable(onClick = onClick)
                .testTag("dot-${state.num}"),
            contentAlignment = Alignment.Center,
        ) {
            Text(state.num, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = foreground)
        }
        if (state.marked) {
            Text("🔖", fontSize = 10.sp, modifier = Modifier.align(Alignment.TopEnd).offset(5.dp, -5.dp))
        }
    }
}
