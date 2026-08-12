package com.qzh.lanjingquiz.UI.Practice

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 大类列表(iOS PracticeCategoryListView 移植):行 = 大类名 + x/N 或 "N 题",
 * 空大类禁用;footer 题库版本 round <n> · 共 <n> 题。更新/删除题库在 我的。
 */
@Composable
fun CategoryListScreen(
    vm: PracticeBankViewModel,
    onOpenCategory: (String) -> Unit,
) {
    val categories by vm.categories.collectAsState()
    val meta by vm.meta.collectAsState()

    Column(Modifier.fillMaxSize()) {
        Text(
            "题库分类",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xFF8E8E93),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        )
        LazyColumn(Modifier.weight(1f)) {
            items(categories, key = { it.name }) { category ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = category.count > 0) { onOpenCategory(category.name) }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(category.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF3C3C3C))
                    Spacer(Modifier.weight(1f))
                    Text(
                        if (category.answered > 0) "${category.answered}/${category.count}" else "${category.count} 题",
                        fontSize = 14.sp,
                        color = if (category.count > 0) Color(0xFF8E8E93) else Color(0xFFC7C7CC),
                    )
                }
                HorizontalDivider(color = Color(0xFFE5E5EA), modifier = Modifier.padding(horizontal = 16.dp))
            }
            item {
                meta?.let { m ->
                    Text(
                        "题库版本 round ${m.round} · 共 ${m.totalCount} 题",
                        fontSize = 13.sp,
                        color = Color(0xFF8E8E93),
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    )
                }
            }
        }
    }
}
