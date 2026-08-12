package com.qzh.lanjingquiz.UI

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.UI.ExamList.ExamListScreen
import com.qzh.lanjingquiz.UI.Login.LoginScreen
import com.qzh.lanjingquiz.UI.Login.LoginViewModel
import com.qzh.lanjingquiz.UI.Practice.BankPhase
import com.qzh.lanjingquiz.UI.Practice.PracticeBankScreen
import com.qzh.lanjingquiz.UI.Practice.PracticeBankViewModel
import com.qzh.lanjingquiz.UI.Practice.PracticeQuizScreen
import com.qzh.lanjingquiz.UI.Practice.PracticeQuizViewModel
import com.qzh.lanjingquiz.UI.Practice.PracticeRoute
import com.qzh.lanjingquiz.UI.Practice.SubcategoryListScreen
import com.qzh.lanjingquiz.UI.Quiz.QuizScreen
import com.qzh.lanjingquiz.UI.Result.ResultScreen

enum class HomeTab { Exams, Practice, Profile }

@Composable
fun AppRoot(appState: AppState) {
    val route by appState.route.collectAsState()
    val notice by appState.notice.collectAsState()
    var splashDone by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { appState.start(); splashDone = true }

    Box(Modifier.fillMaxSize()) {
        val currentRoute = route   // 局部非委托 val,允许 when 分支智能转换
        when (currentRoute) {
            Route.Login -> {
                val loginVm = hiltViewModel<LoginViewModel>()
                // 会话级登录错误(上游回登录页)→ AppState 统一处理(清会话+通知+回登录页)
                LaunchedEffect(loginVm, appState) { loginVm.onSessionError = appState::handleSessionExpiry }
                LoginScreen(vm = loginVm, onFinished = appState::finishLogin)
            }
            Route.Home -> HomeTabHost(appState)
            is Route.Quiz -> QuizScreen(exam = currentRoute.exam, appState = appState)
            is Route.Result -> ResultScreen(result = currentRoute.result, examName = currentRoute.examName, appState = appState)
        }
        notice?.let { NoticeBanner(it) { appState.showNotice(null) } }
        // 简单静态启动页;fade-out 0.45s(iOS 0.45s 淡出对齐)
        AnimatedVisibility(
            visible = !splashDone,
            exit = fadeOut(animationSpec = tween(durationMillis = 450)),
        ) {
            SplashScreen()
        }
    }
}

@Composable
fun HomeTabHost(appState: AppState) {
    val tab by appState.selectedTab.collectAsState()
    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(
                selected = tab == HomeTab.Exams,
                onClick = { appState.selectedTab.value = HomeTab.Exams },
                icon = { Icon(Icons.Filled.CheckCircle, contentDescription = null) },
                label = { Text("考试列表") },
            )
            NavigationBarItem(
                selected = tab == HomeTab.Practice,
                onClick = { appState.selectedTab.value = HomeTab.Practice },
                icon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                label = { Text("练习") },
            )
            NavigationBarItem(
                selected = tab == HomeTab.Profile,
                onClick = { appState.selectedTab.value = HomeTab.Profile },
                icon = { Icon(Icons.Filled.Person, contentDescription = null) },
                label = { Text("我的") },
            )
        }
    }) { padding ->
        when (tab) {
            HomeTab.Exams -> Box(Modifier.padding(padding)) { ExamListScreen() }
            HomeTab.Practice -> PracticeTabHost(appState, padding)
            HomeTab.Profile -> ProfileScreenPlaceholder(padding)  // T6 替换
        }
    }
}

/**
 * 练习 Tab 容器:分类列表 → 题型列表 → 刷题(内部状态切换,route 恒在 Home 内;
 * Hoist 在 AppState,切 Tab 后导航保留)。题库进入爬取/重爬 → 弹回分类根(镜像 iOS dismiss)。
 */
@Composable
fun PracticeTabHost(appState: AppState, padding: PaddingValues) {
    val bankVm: PracticeBankViewModel = hiltViewModel()
    val quizVm: PracticeQuizViewModel = hiltViewModel()
    val route by appState.practiceRoute.collectAsState()
    val phase by bankVm.phase.collectAsState()

    LaunchedEffect(phase) {
        if (phase is BankPhase.Crawling && route != PracticeRoute.Categories) {
            appState.practiceRoute.value = PracticeRoute.Categories
        }
    }

    val currentRoute = route   // 局部非委托 val,允许 when 分支智能转换
    Box(Modifier.padding(padding)) {
        when (currentRoute) {
            PracticeRoute.Categories -> PracticeBankScreen(
                appState = appState,
                vm = bankVm,
                onOpenCategory = { appState.practiceRoute.value = PracticeRoute.Subcategories(it) },
                onStart = { category, subCategory ->
                    appState.practiceRoute.value = PracticeRoute.Quiz(category, subCategory)
                },
            )
            is PracticeRoute.Subcategories -> SubcategoryListScreen(
                vm = bankVm,
                category = currentRoute.category,
                onStart = { category, subCategory ->
                    appState.practiceRoute.value = PracticeRoute.Quiz(category, subCategory)
                },
                onBack = { appState.practiceRoute.value = PracticeRoute.Categories },
            )
            is PracticeRoute.Quiz -> PracticeQuizScreen(
                appState = appState,
                bankVm = bankVm,
                vm = quizVm,
                category = currentRoute.category,
                subCategory = currentRoute.subCategory,
                onBack = { appState.practiceRoute.value = PracticeRoute.Subcategories(currentRoute.category) },
            )
        }
    }
}

/** DSOrange 背景通知横幅,Text(13sp semibold 白),右上 xmark。 */
@Composable
private fun BoxScope.NoticeBanner(text: String, onDismiss: () -> Unit) {
    Surface(
        color = DSOrange,
        shape = MaterialTheme.shapes.large,
        modifier = Modifier
            .fillMaxWidth()
            .align(Alignment.TopCenter)
            .statusBarsPadding()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        shadowElevation = 4.dp,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = text,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "关闭",
                tint = Color.White.copy(alpha = 0.9f),
                modifier = Modifier
                    .size(20.dp)
                    .clickable(onClick = onDismiss)
                    .padding(4.dp),
            )
        }
    }
}

/** 简单静态启动页:图标 + 标题 + 标语(纯装饰,无动画美术)。 */
@Composable
private fun SplashScreen() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(Color(0xFF063E74), Color(0xFF087AB8), Color(0xFF1CB0F6)),
                ),
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("🐳", fontSize = 72.sp)
            Text("蓝鲸助手", fontSize = 29.sp, fontWeight = FontWeight.Black, color = Color.White)
            Text(
                "让每一次练习，都更清晰",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White.copy(alpha = 0.78f),
            )
        }
    }
}
