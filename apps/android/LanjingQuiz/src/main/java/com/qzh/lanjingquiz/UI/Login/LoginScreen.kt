package com.qzh.lanjingquiz.UI.Login

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
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSRed

/** 两屏登录流程:落地页(密码登录入口 + 协议勾选)→ 密码页(手机号/密码/登录)。 */
@Composable
fun LoginScreen(vm: LoginViewModel, appState: AppState, onFinished: () -> Unit) {
    var page by remember { mutableStateOf(0) } // 0 落地页, 1 密码页
    val error by vm.errorMessage.collectAsState()
    val phone by vm.phone.collectAsState()
    val password by vm.password.collectAsState()
    val submitting by vm.isSubmitting.collectAsState()
    val showPassword by vm.showPassword.collectAsState()
    val agreed by vm.agreedToTerms.collectAsState()
    var showAgreementAlert by remember { mutableStateOf(false) }
    var showHelp by remember { mutableStateOf(false) }
    var showForgotPassword by remember { mutableStateOf(false) }
    var showTerms by remember { mutableStateOf(false) }
    var showPrivacy by remember { mutableStateOf(false) }

    // 成功路径:onFinished 即 AppRoot 注入的 AppState.finishLogin(同一实例)
    LaunchedEffect(Unit) { vm.onFinished = onFinished }

    // 登录页出现时重试一次云端拉取(iOS LoginView .task → retryCloudSyncIfNeeded):
    // 启动时拉取受 4s 边界限制,云端会话稍晚同步完成会把用户留在登录页;用户已输入不打断。
    LaunchedEffect(Unit) { appState.retryCloudSyncIfNeeded(vm.phone.value, vm.password.value) }

    Box(Modifier.fillMaxSize().systemBarsPadding()) {
        if (page == 0) {
            LandingPage(
                agreed = agreed,
                onToggleAgreed = { vm.agreedToTerms.value = !agreed },
                onEnter = {
                    if (agreed) page = 1 else showAgreementAlert = true
                },
                onShowTerms = { showTerms = true },
                onShowPrivacy = { showPrivacy = true },
                onHelp = { showHelp = true },
            )
        } else {
            PasswordPage(
                phone = phone,
                password = password,
                submitting = submitting,
                showPassword = showPassword,
                onPhoneChange = { vm.phone.value = it },
                onPasswordChange = { vm.password.value = it },
                onTogglePassword = { vm.showPassword.value = !showPassword },
                onBack = { page = 0 },
                onSubmit = {
                    if (agreed) vm.submit() else showAgreementAlert = true
                },
                onForgotPassword = { showForgotPassword = true },
                onHelp = { showHelp = true },
            )
        }
        // 顶部红色错误条
        error?.let {
            Surface(
                color = DSRed,
                shape = MaterialTheme.shapes.extraLarge,
                modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter).padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Text(
                    it,
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    }

    if (showAgreementAlert) {
        AlertDialog(
            onDismissRequest = { showAgreementAlert = false },
            title = { Text("请先同意协议") },
            text = { Text("登录前请阅读并同意用户协议与隐私政策。") },
            confirmButton = {
                TextButton(onClick = { showAgreementAlert = false }) { Text("知道了") }
            },
        )
    }
    if (showHelp) {
        AlertDialog(
            onDismissRequest = { showHelp = false },
            title = { Text("登录帮助") },
            text = { Text("请输入注册手机号和密码。如果忘记密码，请联系管理员重置。") },
            confirmButton = {
                TextButton(onClick = { showHelp = false }) { Text("知道了") }
            },
        )
    }
    if (showForgotPassword) {
        AlertDialog(
            onDismissRequest = { showForgotPassword = false },
            title = { Text("忘记密码") },
            text = { Text("请联系管理员重置密码。") },
            confirmButton = {
                TextButton(onClick = { showForgotPassword = false }) { Text("知道了") }
            },
        )
    }
    if (showTerms) {
        AlertDialog(
            onDismissRequest = { showTerms = false },
            title = { Text("用户协议") },
            text = { Text("蓝鲸助手用户协议将在后续版本中提供。") },
            confirmButton = {
                TextButton(onClick = { showTerms = false }) { Text("知道了") }
            },
        )
    }
    if (showPrivacy) {
        AlertDialog(
            onDismissRequest = { showPrivacy = false },
            title = { Text("隐私政策") },
            text = { Text("蓝鲸助手隐私政策将在后续版本中提供。") },
            confirmButton = {
                TextButton(onClick = { showPrivacy = false }) { Text("知道了") }
            },
        )
    }
}

@Composable
private fun LandingPage(
    agreed: Boolean,
    onToggleAgreed: () -> Unit,
    onEnter: () -> Unit,
    onShowTerms: () -> Unit,
    onShowPrivacy: () -> Unit,
    onHelp: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        TopBar(showBack = false, onHelp = onHelp)

        Spacer(Modifier.weight(1f))

        Text("🐳", fontSize = 96.sp)
        Text(
            "蓝鲸助手",
            fontSize = 34.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            "让每一次练习，都更清晰",
            fontSize = 15.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.weight(1f))

        Button(
            onClick = onEnter,
            modifier = Modifier
                .fillMaxWidth()
                .height(58.dp)
                .testTag("password-login-entry"),
            shape = MaterialTheme.shapes.extraLarge,
            colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
        ) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = Color.White)
            Spacer(Modifier.width(8.dp))
            Text("密码登录", fontSize = 19.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        }

        AgreementRow(
            agreed = agreed,
            onToggle = onToggleAgreed,
            onShowTerms = onShowTerms,
            onShowPrivacy = onShowPrivacy,
        )
    }
}

@Composable
private fun AgreementRow(
    agreed: Boolean,
    onToggle: () -> Unit,
    onShowTerms: () -> Unit,
    onShowPrivacy: () -> Unit,
) {
    Row(
        modifier = Modifier.padding(top = 30.dp, bottom = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = agreed, onCheckedChange = { onToggle() })
        Text("我已阅读并同意", color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = onShowTerms) {
            Text("用户协议", color = MaterialTheme.colorScheme.onSurface)
        }
        Text("与", color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = onShowPrivacy) {
            Text("隐私政策", color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun PasswordPage(
    phone: String,
    password: String,
    submitting: Boolean,
    showPassword: Boolean,
    onPhoneChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onTogglePassword: () -> Unit,
    onBack: () -> Unit,
    onSubmit: () -> Unit,
    onForgotPassword: () -> Unit,
    onHelp: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        TopBar(showBack = true, onBack = onBack, onHelp = onHelp)

        Text(
            "密码登录",
            fontSize = 31.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.fillMaxWidth().padding(top = 58.dp),
        )

        Column(
            modifier = Modifier.fillMaxWidth().padding(top = 32.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            OutlinedTextField(
                value = phone,
                onValueChange = onPhoneChange,
                modifier = Modifier.fillMaxWidth().testTag("login-phone"),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                singleLine = true,
                leadingIcon = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("+86", fontSize = 18.sp, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.width(12.dp))
                        Text("|", color = MaterialTheme.colorScheme.outline)
                    }
                },
                placeholder = { Text("手机号") },
            )
            OutlinedTextField(
                value = password,
                onValueChange = onPasswordChange,
                modifier = Modifier.fillMaxWidth().testTag("login-password"),
                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                singleLine = true,
                placeholder = { Text("密码") },
                trailingIcon = {
                    TextButton(onClick = onTogglePassword) {
                        Text(if (showPassword) "隐藏密码" else "显示密码")
                    }
                },
            )
            TextButton(onClick = onForgotPassword, modifier = Modifier.align(Alignment.Start)) {
                Text("忘记密码", color = MaterialTheme.colorScheme.primary)
            }
        }

        Spacer(Modifier.weight(1f))

        Button(
            onClick = onSubmit,
            enabled = !submitting,
            modifier = Modifier.fillMaxWidth().height(58.dp).testTag("password-login-submit"),
            shape = MaterialTheme.shapes.extraLarge,
            colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
        ) {
            if (submitting) {
                CircularProgressIndicator(modifier = Modifier.size(24.dp), color = Color.White, strokeWidth = 2.5.dp)
            } else {
                Text("登录", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            }
        }
        Spacer(Modifier.height(22.dp))
    }
}

@Composable
private fun TopBar(showBack: Boolean, onBack: () -> Unit = {}, onHelp: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showBack) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
            }
        } else {
            Spacer(Modifier.size(48.dp))
        }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onHelp) {
            Text("帮助", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
