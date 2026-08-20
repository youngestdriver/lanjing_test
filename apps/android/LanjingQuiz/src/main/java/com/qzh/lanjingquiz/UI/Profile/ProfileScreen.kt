package com.qzh.lanjingquiz.UI.Profile

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.ThemeMode
import com.qzh.lanjingquiz.BuildConfig
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSRed
import com.qzh.lanjingquiz.UI.Practice.PracticeBankSettingsSection
import androidx.compose.foundation.layout.PaddingValues

/**
 * 我的页(iOS ProfileView 移植):账户(已登录)/外观(跟随系统颜色设置 + 深色模式)/
 * 答题设置(答对后自动下一题)/题库设置(复用 T5 PracticeBankSettingsSection)/
 * Cookie 云端同步(服务器地址/UUID/密码/立即同步 + 状态)/退出登录(确认后 appState.logout())/
 * 版本 "1.0 (1)"。文案逐字 spec §3.5 与 iOS。
 */
@Composable
fun ProfileScreen(
    appState: AppState,
    padding: PaddingValues,
    vm: ProfileViewModel = hiltViewModel(),
) {
    val theme by appState.theme.collectAsState()
    val autoAdvance by appState.autoAdvance.collectAsState()
    val cloudEnabled by vm.cloudEnabled.collectAsState()
    val server by vm.cloudServer.collectAsState()
    val uuid by vm.cloudUuid.collectAsState()
    val password by vm.cloudPassword.collectAsState()
    val syncStatus by vm.syncStatus.collectAsState()
    val isSyncing by vm.isSyncing.collectAsState()
    var confirmLogout by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .padding(padding)
            .verticalScroll(rememberScrollState()),
    ) {
        // 账户
        SectionHeader("账户")
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = DSAccent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("已登录", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = DSAccent)
        }

        // 外观
        SectionHeader("外观")
        SwitchRow("跟随系统颜色设置", theme == ThemeMode.System) { appState.setFollowsSystem(it) }
        if (theme != ThemeMode.System) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { appState.toggleTheme() }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("深色模式", fontSize = 16.sp, modifier = Modifier.weight(1f))
                if (theme == ThemeMode.Dark) {
                    Icon(Icons.Filled.Check, contentDescription = null, tint = DSAccent, modifier = Modifier.size(20.dp))
                }
            }
        }

        // 答题设置
        SectionHeader("答题设置")
        SwitchRow("答对后自动下一题", autoAdvance) { appState.setAutoAdvance(it) }

        // 题库设置(T5 复用:更新/删除/日志导出)
        PracticeBankSettingsSection()

        // Cookie 云端同步
        SectionHeader("云端同步")
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Cookie 云端同步", fontSize = 16.sp, modifier = Modifier.weight(1f))
            Switch(checked = cloudEnabled, onCheckedChange = vm::setCloudEnabled)
        }
        OutlinedTextField(
            value = server,
            onValueChange = vm::setCloudServer,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            label = { Text("服务器地址") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            singleLine = true,
        )
        OutlinedTextField(
            value = uuid,
            onValueChange = vm::setCloudUuid,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            label = { Text("UUID") },
            singleLine = true,
        )
        OutlinedTextField(
            value = password,
            onValueChange = vm::setCloudPassword,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            label = { Text("密码") },
            visualTransformation = PasswordVisualTransformation(),
            singleLine = true,
        )
        Button(
            onClick = { vm.syncNow() },
            enabled = vm.isConfigured && !isSyncing,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            if (isSyncing) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            } else {
                Text("立即同步")
            }
        }
        syncStatus?.let {
            Text(
                it,
                fontSize = 13.sp,
                color = Color(0xFF8E8E93),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        Text(
            "登录凭证会加密后上传到你配置的服务器；UUID 与密码需与浏览器扩展一致，服务地址是你自建的 CookieCloud。",
            fontSize = 12.sp,
            color = Color(0xFF8E8E93),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )

        // 退出登录
        HorizontalDivider(color = Color(0xFFE5E5EA))
        Button(
            onClick = { confirmLogout = true },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            colors = ButtonDefaults.buttonColors(containerColor = DSRed),
        ) {
            Text("退出登录", color = Color.White)
        }

        // 版本
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
            Text("版本", fontSize = 16.sp, modifier = Modifier.weight(1f))
            Text(
                "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                fontSize = 16.sp,
                color = Color(0xFF8E8E93),
            )
        }
    }

    if (confirmLogout) {
        AlertDialog(
            onDismissRequest = { confirmLogout = false },
            title = { Text("退出登录") },
            text = { Text("确定退出登录吗？") },
            confirmButton = {
                Button(
                    onClick = {
                        confirmLogout = false
                        appState.logout()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = DSRed),
                ) { Text("退出登录", color = Color.White) }
            },
            dismissButton = {
                TextButton(onClick = { confirmLogout = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, fontSize = 16.sp, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun SectionHeader(title: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF8E8E93))
    }
    HorizontalDivider(color = Color(0xFFE5E5EA))
}
