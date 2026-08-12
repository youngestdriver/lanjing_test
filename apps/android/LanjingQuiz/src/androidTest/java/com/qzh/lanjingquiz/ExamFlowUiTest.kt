package com.qzh.lanjingquiz

import android.content.Context
import android.content.Intent
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.qzh.lanjingquiz.App.MainActivity
import com.qzh.lanjingquiz.Network.TestConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 考试全流程 UI 测试(登录 → 列表 → 进入[新卷队列] → 作答 → 答题卡 → 交卷 → 结果),
 * 全程 MockUpstreamServer 封闭运行(不触真实上游)。本地仅编译门禁,CI 模拟器执行。
 *
 * baseUrl 注入机制:ActivityScenario launch intent extra("mockBaseUrl"),
 * MainActivity.onCreate(debug 守卫)写入 TestConfig,全 App(ApiClient + WebView)指向 mock。
 */
@RunWith(AndroidJUnit4::class)
class ExamFlowUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var server: MockUpstreamServer

    @Before
    fun setUp() {
        server = MockUpstreamServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun fullExamFlow() {
        // 双保险:(1) 直接写 TestConfig(仪器化进程与 App 同进程,先于任何请求生效);
        // (2) intent extra 经 MainActivity.onCreate 再写一次。ApiClient 按请求惰性解析 base URL,
        //     故两者都早于首个网络请求。
        TestConfig.mockBaseUrl = server.baseUrl()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(TestConfig.EXTRA_MOCK_BASE_URL, server.baseUrl())
        ActivityScenario.launch<MainActivity>(intent)

        // 登录页(落地页 → 密码登录)
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithTag("password-login-entry").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("password-login-entry").performClick()
        composeRule.onNodeWithTag("login-phone").performTextInput("13800000000")
        composeRule.onNodeWithTag("login-password").performTextInput("123456")
        composeRule.onNodeWithTag("password-login-submit").performClick()

        // 考试列表:"机考题库"组 + 新试卷徽标
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("机考题库").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("机考题库").assertIsDisplayed()
        composeRule.onNodeWithText("新试卷").assertIsDisplayed()

        // 进入 111(新卷 wfs=1 → 完整队列流程)
        composeRule.onNodeWithTag("exam-card-111").performClick()

        // 答题页:第 1 题可见
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("第 1 / 4 题").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("第 1 / 4 题").assertIsDisplayed()

        // 第 1 题单选 key1(A):点 B → 判错(红)
        composeRule.onNodeWithTag("option-1-B").performClick()
        composeRule.onNodeWithText("加油！再接再厉！").assertIsDisplayed()
        composeRule.onNodeWithText("正确答案：A").assertIsDisplayed()

        // 答题卡:网格可见 → 跳第 3 题
        composeRule.onNodeWithTag("answer-card-btn").performClick()
        composeRule.onNodeWithTag("dot-3").assertIsDisplayed()
        composeRule.onNodeWithTag("dot-3").performClick()
        composeRule.onNodeWithTag("answer-card-close").performClick()
        composeRule.onNodeWithText("第 3 / 4 题").assertIsDisplayed()

        // 第 3 题多选(key1+key3):点 A、C → 提交 → 判对(绿)
        composeRule.onNodeWithTag("option-3-A").performClick()
        composeRule.onNodeWithTag("option-3-C").performClick()
        composeRule.onNodeWithTag("multi-submit").performClick()
        composeRule.onNodeWithText("棒极了！回答正确！").assertIsDisplayed()

        // 交卷 → 两段确认 → 结果页 "88 分"
        composeRule.onNodeWithTag("submit-exam").performClick()
        composeRule.onNodeWithText("确定提交试卷吗？").assertIsDisplayed()
        composeRule.onNodeWithTag("confirm-submit").performClick()
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithTag("result-score").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("88 分").assertIsDisplayed()
        composeRule.onNodeWithText("击败全国 72% 的考生").assertIsDisplayed()
        composeRule.onNodeWithText("当前排名 #35").assertIsDisplayed()

        // 服务端断言:提交记录(q1 错选 B → "key2,";q3 多选 → "key1,key3,")
        assertEquals("key2,", server.submittedAnswers["q1"])
        assertEquals("key1,key3,", server.submittedAnswers["q3"])
        // 新卷队列流程真实发生
        assertTrue(server.seenRequests.contains("POST /exam/start_exam_queue"))
        assertTrue(server.seenRequests.contains("POST /exam/test_complete"))
        assertTrue(server.seenRequests.contains("GET /exam/exam_start/111"))
        assertTrue(server.seenRequests.contains("GET /exam/exam_ending"))
    }
}
