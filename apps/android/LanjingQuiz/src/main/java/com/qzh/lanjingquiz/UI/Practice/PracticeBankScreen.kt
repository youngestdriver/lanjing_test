package com.qzh.lanjingquiz.UI.Practice

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.Domain.Crawler
import com.qzh.lanjingquiz.UI.DSAccent

/**
 * 练习 Tab 根屏(iOS PracticeBankView 移植):爬取状态机 UI。
 * Idle → LaunchedEffect ensureBankReady;Checking → 正在检查题库…;NeedsLogin →
 * 去登录;Crawling → 进度;Failed → 重试;Ready → CategoryListScreen。
 * 我的 > 删除题库(bankResetVersion+1)→ 重置本 VM 并重爬。
 */
@Composable
fun PracticeBankScreen(
    appState: AppState,
    vm: PracticeBankViewModel = hiltViewModel(),
    onOpenCategory: (String) -> Unit,
    onStart: (category: String, subCategory: String) -> Unit,
) {
    val phase by vm.phase.collectAsState()
    val resetVersion by appState.bankResetVersion.collectAsState()

    // 删除题库后:重置本 VM 状态并重爬(初始 0 不触发)
    LaunchedEffect(resetVersion) {
        if (resetVersion > 0) {
            vm.bankWasDeleted()
            vm.ensureBankReady()
        }
    }

    val currentPhase = phase   // 局部非委托 val,允许 when 分支智能转换
    when (currentPhase) {
        BankPhase.Idle -> {
            LaunchedEffect(Unit) { vm.ensureBankReady() }
            CenterProgress("正在检查题库…")
        }
        BankPhase.Checking -> CenterProgress("正在检查题库…")
        BankPhase.NeedsLogin -> EmptyState(
            title = "需要登录",
            message = "练习题目直接从蓝鲸平台获取，登录后才能使用。",
            action = {
                TextButton(onClick = { appState.navigateTo(Route.Login) }) {
                    Text("去登录", fontWeight = FontWeight.Bold, color = DSAccent)
                }
            },
        )
        is BankPhase.Crawling -> CrawlProgressUi(currentPhase.progress)
        is BankPhase.Failed -> ErrorRetry(
            message = currentPhase.message,
            onRetry = vm::ensureBankReady,
        )
        BankPhase.Ready -> CategoryListScreen(
            vm = vm,
            onOpenCategory = onOpenCategory,
        )
    }
}

@Composable
private fun CenterProgress(text: String) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator(color = DSAccent)
        Text(
            text,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xFF8E8E93),
            modifier = Modifier.padding(top = 12.dp),
        )
    }
}

@Composable
private fun EmptyState(title: String, message: String, action: @Composable () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
        Text(
            message,
            fontSize = 14.sp,
            color = Color(0xFF8E8E93),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp),
        )
        action()
    }
}

/** "正在爬取题库(x/y)" + 当前卷名 + 线性进度条。 */
@Composable
private fun CrawlProgressUi(progress: Crawler.CrawlProgress) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        LinearProgressIndicator(
            progress = {
                if (progress.total > 0) progress.current.toFloat() / progress.total else 0f
            },
            color = DSAccent,
            modifier = Modifier.width(260.dp),
        )
        if (progress.total > 0) {
            Text(
                "正在爬取题库(${progress.current}/${progress.total})",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xFF3C3C3C),
                modifier = Modifier.padding(top = 16.dp),
            )
            progress.paperName?.let {
                Text(it, fontSize = 13.sp, color = Color(0xFF8E8E93), modifier = Modifier.padding(top = 4.dp))
            }
        } else {
            Text(
                "正在爬取题库…",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xFF3C3C3C),
                modifier = Modifier.padding(top = 16.dp),
            )
        }
    }
}

/** 题库爬取失败:消息 + 说明 + 重试(iOS ContentUnavailableView)。 */
@Composable
private fun ErrorRetry(message: String, onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("题库爬取失败", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
        Text(
            "$message\n\n请检查网络后重试;已爬取的题目会保留，重试会从中断处继续。",
            fontSize = 14.sp,
            color = Color(0xFF8E8E93),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp),
        )
        Button(
            onClick = onRetry,
            modifier = Modifier.padding(top = 16.dp),
            shape = MaterialTheme.shapes.extraLarge,
            colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
        ) {
            Text("重试", color = Color.White)
        }
    }
}
