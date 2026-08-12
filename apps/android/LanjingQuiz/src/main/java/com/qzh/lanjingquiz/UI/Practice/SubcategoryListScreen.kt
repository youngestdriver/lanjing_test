package com.qzh.lanjingquiz.UI.Practice

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 题型细分列表(iOS PracticeSubcategoryListView 移植):顶部随机顺序开关
 * (每大类独立记忆,键 practice.shuffle.<大类>)+ 题型行 x/N + 空状态。
 */
@Composable
fun SubcategoryListScreen(
    vm: PracticeBankViewModel,
    category: String,
    onStart: (category: String, subCategory: String) -> Unit,
    onBack: () -> Unit,
) {
    val subcategories by vm.subcategories.collectAsState()
    var shuffle by remember { mutableStateOf(vm.shuffleEnabled(category)) }

    BackHandler(onBack = onBack)
    LaunchedEffect(category) {
        vm.openCategory(category)
        shuffle = vm.shuffleEnabled(category)
    }

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "‹",
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                color = Color(0xFF8E8E93),
                modifier = Modifier
                    .clickable(onClick = onBack)
                    .padding(end = 12.dp),
            )
            Text(category, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("随机顺序", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF3C3C3C))
                Text(
                    "开启后本大类下每次练习按随机顺序出题；资料分析中共享同一材料的题目会保持在一起",
                    fontSize = 12.sp,
                    color = Color(0xFF8E8E93),
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            Switch(
                checked = shuffle,
                onCheckedChange = {
                    shuffle = it
                    vm.setShuffleEnabled(it, category)
                },
            )
        }

        Text(
            "题型",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xFF8E8E93),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        )

        if (subcategories.isEmpty()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("该分类暂无题目", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
                Text(
                    "本地题库可能不完整，请在 我的 > 更新题库 重新爬取。",
                    fontSize = 14.sp,
                    color = Color(0xFF8E8E93),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        } else {
            LazyColumn(Modifier.weight(1f)) {
                items(subcategories, key = { it.name }) { sub ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = sub.count > 0) { onStart(category, sub.name) }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(sub.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF3C3C3C))
                        Spacer(Modifier.weight(1f))
                        Text(
                            if (sub.answered > 0) "${sub.answered}/${sub.count}" else "${sub.count} 题",
                            fontSize = 14.sp,
                            color = if (sub.count > 0) Color(0xFF8E8E93) else Color(0xFFC7C7CC),
                        )
                    }
                    HorizontalDivider(color = Color(0xFFE5E5EA), modifier = Modifier.padding(horizontal = 16.dp))
                }
            }
        }
    }
}
