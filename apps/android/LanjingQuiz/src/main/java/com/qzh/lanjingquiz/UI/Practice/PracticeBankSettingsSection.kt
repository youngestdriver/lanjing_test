package com.qzh.lanjingquiz.UI.Practice

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.Support.Formatters
import java.io.File

/**
 * 我的 > 题库设置(iOS PracticeBankSettingsSection 移植):更新题库(重爬全部,成功才
 * 原子替换)/ 删除题库(两段确认,清空 bank + 日志 + session/progress,通知 + bankResetVersion)
 * + 日志导出(FileProvider → ACTION_SEND 分享 txt)。T6 我的页消费。
 */
@Composable
fun PracticeBankSettingsSection(vm: PracticeBankViewModel = hiltViewModel()) {
    val context = LocalContext.current
    val phase by vm.phase.collectAsState()
    var confirmDelete by remember { mutableStateOf(false) }
    var logStatus by remember { mutableStateOf<String?>(null) }

    val isCrawling = phase is BankPhase.Crawling
    val crawlProgress = (phase as? BankPhase.Crawling)?.progress

    Column {
        SectionHeader("题库")
        Button(
            onClick = { vm.refreshBank() },
            enabled = !isCrawling,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            Text("更新题库")
        }
        if (isCrawling && crawlProgress != null) {
            LinearProgressIndicator(
                progress = {
                    if (crawlProgress.total > 0) crawlProgress.current.toFloat() / crawlProgress.total else 0f
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
            )
            if (crawlProgress.total > 0) {
                Text(
                    "正在爬取题库(${crawlProgress.current}/${crawlProgress.total})${crawlProgress.paperName?.let { " $it" } ?: ""}",
                    fontSize = 13.sp,
                    color = Color(0xFF8E8E93),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
        }
        Button(
            onClick = { confirmDelete = true },
            enabled = !isCrawling,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF4B4B)),
        ) {
            Text("删除题库", color = Color.White)
        }

        SectionHeader("日志")
        Button(
            onClick = { exportLog(context, vm) { logStatus = it } },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            Text("日志导出")
        }
        logStatus?.let {
            Text(
                it,
                fontSize = 13.sp,
                color = Color(0xFF8E8E93),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("删除本地题库？") },
            text = { Text("本地题库将被清空（含爬取日志），再次进入练习页会重新从蓝鲸平台爬取全部试卷，每张新卷占用一次作答机会并自动结束。") },
            confirmButton = {
                Button(
                    onClick = {
                        confirmDelete = false
                        vm.deleteBank()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF4B4B)),
                ) { Text("删除题库", color = Color.White) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun SectionHeader(title: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF8E8E93))
    }
    HorizontalDivider(color = Color(0xFFE5E5EA))
}

/**
 * 导出爬取日志:写 cacheDir/BankExport/爬取日志_yyyyMMdd_HHmm.txt(UTF-8)
 * → FileProvider content:// URI → ACTION_SEND text/plain。
 * 空日志 → "暂无爬取日志（完成一次爬取后生成）";失败 → "导出失败：{message}"。
 */
private fun exportLog(context: Context, vm: PracticeBankViewModel, onStatus: (String?) -> Unit) {
    val text = vm.exportLog()
    if (text == null) {
        onStatus("暂无爬取日志（完成一次爬取后生成）")
        return
    }
    val result = runCatching {
        val dir = File(context.cacheDir, "BankExport")
        dir.mkdirs()
        val file = File(dir, Formatters.exportFileName())
        file.writeText(text, Charsets.UTF_8)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, null))
    }
    onStatus(result.exceptionOrNull()?.let { "导出失败：${it.message}" })
}
