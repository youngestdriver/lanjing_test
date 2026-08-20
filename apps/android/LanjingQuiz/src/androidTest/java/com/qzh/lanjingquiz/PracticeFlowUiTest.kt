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
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.qzh.lanjingquiz.App.MainActivity
import com.qzh.lanjingquiz.Network.TestConfig
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 练习全流程 UI 测试(登录 → 练习 → 爬取 → 分类 → 刷题 → 退出重进恢复进度),
 * 全程 MockUpstreamServer 封闭运行(不触真实上游)。本地仅编译门禁,CI 模拟器执行。
 *
 * 爬取目标:mock 考试列表含 2 份机考题库卷(言语理解 wfs=1 / 数字运算 wfs=0),
 * 答题卡与题目批拉取复用考试夹具 → 言语理解 4 题入库(section 科技常识/逻辑推理
 * 无分类规则 → 子类兜底"其他")。
 */
@RunWith(AndroidJUnit4::class)
class PracticeFlowUiTest {

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
    fun fullPracticeFlow() {
        // baseUrl 注入机制与 ExamFlowUiTest 相同(双保险:TestConfig 直接写 + intent extra)
        TestConfig.mockBaseUrl = server.baseUrl()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(TestConfig.EXTRA_MOCK_BASE_URL, server.baseUrl())
        ActivityScenario.launch<MainActivity>(intent)

        // 未登录走登录流程;同次 instrumentation 会话残留上一测试的会话时直达首页
        loginIfNeeded()

        // 练习 Tab → 本地无题库 → 自动全量爬取(增量"正在爬取题库(x/y)")→ 分类列表
        composeRule.onNodeWithText("练习").performClick()
        composeRule.waitUntil(timeoutMillis = 60_000) {
            composeRule.onAllNodesWithText("言语理解").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("言语理解").assertIsDisplayed()
        // 爬取真实发生:新卷(wfs=1)完整队列流程 + 批拉取
        assertTrue(server.seenRequests.contains("POST /exam/start_exam_queue"))
        assertTrue(server.seenRequests.contains("POST /exam/get_question_info/"))

        // 大类 → 题型细分(兜底"其他",4 题)→ 刷题
        composeRule.onNodeWithText("言语理解").performClick()
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("其他").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("其他").performClick()

        // 第 1 题单选 key1(A):点 A → 判对(绿)
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("第 1/4 题").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("practice-option-A").performClick()
        composeRule.onNodeWithText("棒极了！回答正确！").assertIsDisplayed()
        composeRule.onNodeWithText("正确答案：A").assertIsDisplayed()

        // 退出(系统返回 → 题型列表)→ 重进 → 恢复上次进度(答案状态一并恢复)
        Espresso.pressBack()
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("随机顺序").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("其他").performClick()
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("已恢复上次练习进度").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("已恢复上次练习进度").assertIsDisplayed()
        composeRule.onNodeWithText("第 1/4 题").assertIsDisplayed()
        composeRule.onNodeWithText("正确答案：A").assertIsDisplayed()   // 已答状态恢复
    }

    /** 已登录(会话残留)→ 直接等首页;未登录 → 走登录流程。 */
    private fun loginIfNeeded() {
        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithTag("password-login-entry").fetchSemanticsNodes().isNotEmpty() ||
                composeRule.onAllNodesWithText("机考题库").fetchSemanticsNodes().isNotEmpty()
        }
        if (composeRule.onAllNodesWithTag("password-login-entry").fetchSemanticsNodes().isNotEmpty()) {
            composeRule.onNodeWithTag("password-login-entry").performClick()
            composeRule.onNodeWithTag("login-phone").performTextInput("13800000000")
            composeRule.onNodeWithTag("login-password").performTextInput("123456")
            composeRule.onNodeWithTag("password-login-submit").performClick()
            composeRule.waitUntil(timeoutMillis = 15_000) {
                composeRule.onAllNodesWithText("机考题库").fetchSemanticsNodes().isNotEmpty()
            }
        }
    }
}
